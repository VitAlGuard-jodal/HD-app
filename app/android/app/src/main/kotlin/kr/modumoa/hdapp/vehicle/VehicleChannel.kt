package kr.modumoa.hdapp.vehicle

import ai.pleos.playground.vehicle.Vehicle
import ai.pleos.playground.vehicle.api.Door
import ai.pleos.playground.vehicle.api.model.area.DoorArea
import ai.pleos.playground.vehicle.api.model.capability.AreaBounds
import ai.pleos.playground.vehicle.constant.area.DoorValue
import ai.pleos.playground.vehicle.listener.DoorPositionListener
import android.car.Car
import android.car.VehicleGear
import android.car.VehiclePropertyIds
import android.car.hardware.CarPropertyValue
import android.car.hardware.property.CarPropertyManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

/** Only the automotive branch loads the optional android.car/Vehicle classes. */
class VehicleChannel(context: Context, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val context = context.applicationContext
    private val events = EventChannel(messenger, "unavo/vehicle")
    private var stop: (() -> Unit)? = null

    init { events.setStreamHandler(this) }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        onCancel(null)
        try {
            if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)) {
                sink.success(mapOf("available" to false))
                sink.endOfStream()
                return
            }
            Class.forName("android.car.Car")
            val subscription = VehicleSubscription(context, sink)
            stop = subscription::dispose
            subscription.start()
        } catch (error: Exception) {
            unavailable(sink, error.javaClass.simpleName)
        } catch (error: LinkageError) {
            unavailable(sink, error.javaClass.simpleName)
        }
    }

    private fun unavailable(sink: EventChannel.EventSink, reason: String) {
        onCancel(null)
        Log.w("unavo-vehicle", "manual fallback=$reason")
        sink.success(mapOf("available" to false))
        sink.endOfStream()
    }

    override fun onCancel(arguments: Any?) {
        val cleanup = stop
        stop = null
        cleanup?.invoke()
    }

    fun dispose() {
        onCancel(null)
        events.setStreamHandler(null)
    }
}

private class VehicleSubscription(private val context: Context, private val sink: EventChannel.EventSink) {
    private val main = Handler(Looper.getMainLooper())
    private var active = true
    private var vehicle: Vehicle? = null
    private var door: Door? = null
    private var car: Car? = null
    private var gears: CarPropertyManager? = null
    private var pending = 0
    private var parked: Boolean? = null
    private val positions = linkedMapOf<DoorArea, Int?>()
    private val listeners = linkedMapOf<DoorArea, DoorPositionListener>()
    private val versions = mutableMapOf<DoorArea, Int>()
    private var frontDoor: DoorArea? = null
    private var fallbackLogged = false
    private val gearListener = object : CarPropertyManager.CarPropertyEventCallback {
        override fun onChangeEvent(value: CarPropertyValue<*>) {
            main.post {
                if (!active || value.propertyId != VehiclePropertyIds.GEAR_SELECTION) return@post
                val gear = value.value as? Int
                parked = if (value.status == CarPropertyValue.STATUS_AVAILABLE && gear != null && gear != VehicleGear.GEAR_UNKNOWN)
                    gear == VehicleGear.GEAR_PARK else null
                publish()
            }
        }

        override fun onErrorEvent(propertyId: Int, areaId: Int) {
            main.post { if (active) { parked = null; publish() } }
        }
    }

    fun start() {
        // Independent signals: failure of either one is manual readiness mode.
        guarded {
            car = checkNotNull(Car.createCar(context))
            check(car!!.isConnected)
            gears = car!!.getCarManager(Car.PROPERTY_SERVICE) as CarPropertyManager
            check(gears!!.registerCallback(gearListener, VehiclePropertyIds.GEAR_SELECTION, CarPropertyManager.SENSOR_RATE_ONCHANGE))
            val value = gears!!.getProperty<Int>(VehiclePropertyIds.GEAR_SELECTION, 0)
            val gear = value.value
            parked = if (value.status == CarPropertyValue.STATUS_AVAILABLE && gear != VehicleGear.GEAR_UNKNOWN)
                gear == VehicleGear.GEAR_PARK else null
        }
        guarded {
            vehicle = Vehicle(context)
            vehicle!!.initialize()
            door = vehicle!!.getDoor()
            pending++
            try {
                door!!.checkDoorPositionCapabilities(
                    { supported: Map<DoorArea, AreaBounds<Int>> ->
                        main.post {
                            try { if (active) registerDoors(supported) }
                            finally { completed() }
                        }
                    },
                    { error: Exception -> main.post { failed(error); completed() } },
                )
            } catch (error: Exception) { completed(); throw error }
            catch (error: LinkageError) { completed(); throw error }
        }
        publish()
    }

    private fun registerDoors(supported: Map<DoorArea, AreaBounds<Int>>) {
        // Register exactly the capability-reported areas, never guessed doors.
        for (area in supported.keys) positions[area] = null
        frontDoor = supported.keys.firstOrNull { DoorValue.ROW_1_LEFT in it.values }
            ?: supported.keys.firstOrNull { DoorValue.ROW_1_RIGHT in it.values }
        Log.d("unavo-vehicle", "supported doors=${supported.size}; gear=GEAR_SELECTION")
        for ((area, bounds) in supported) {
            val listener = object : DoorPositionListener {
                override fun onPositionUpdated(position: Int?) {
                    main.post {
                        if (!active) return@post
                        versions[area] = (versions[area] ?: 0) + 1
                        positions[area] = position?.takeIf { it >= 0 && it >= bounds.minValue && it <= bounds.maxValue }
                        publish()
                    }
                }
                override fun onFailed(exception: Exception) {
                    main.post {
                        if (!active) return@post
                        versions[area] = (versions[area] ?: 0) + 1
                        positions[area] = null
                        failed(exception)
                    }
                }
            }
            guarded {
                listeners[area] = listener
                door!!.registerDoorPosition(area, listener)
                val version = versions[area] ?: 0
                pending++
                try {
                    door!!.getCurrentDoorPosition(area,
                        { position: Int? -> main.post {
                            if (active && (versions[area] ?: 0) == version) {
                                positions[area] = position?.takeIf { it >= 0 && it >= bounds.minValue && it <= bounds.maxValue }
                                publish()
                            }
                            completed()
                        } },
                        { error: Exception -> main.post {
                            if (active && (versions[area] ?: 0) == version) { positions[area] = null; failed(error) }
                            completed()
                        } },
                    )
                } catch (error: Exception) { completed(); throw error }
                catch (error: LinkageError) { completed(); throw error }
            }
        }
        publish()
    }

    private fun publish() {
        if (!active) return
        val doorsKnown = positions.isNotEmpty() && positions.values.all { it != null }
        val available = doorsKnown && parked != null
        if (!available && !fallbackLogged) {
            fallbackLogged = true
            Log.w("unavo-vehicle", "manual fallback: waiting for supported doors and gear")
        } else if (available) fallbackLogged = false
        sink.success(mapOf(
            "available" to available,
            "doors" to positions.mapKeys { (area, _) -> area.values.joinToString("+") { it.name } },
            "parked" to parked,
            "exitDoor" to frontDoor?.values?.joinToString("+") { it.name },
        ))
    }

    private fun failed(error: Throwable) {
        if (!active) return
        Log.w("unavo-vehicle", "manual fallback=${error.javaClass.simpleName} msg=${error.message}")
        publish()
    }

    private fun guarded(block: () -> Unit) {
        try { block() } catch (error: Exception) { failed(error) }
        catch (error: LinkageError) { failed(error) }
    }

    private fun completed() { pending--; releaseWhenIdle() }

    private fun releaseWhenIdle() {
        // An async capability/get callback may still hold Vehicle. Cancellation
        // silences it, but MUST NOT release the SDK until that callback returns.
        if (active || pending != 0) return
        guarded { vehicle?.release() }
        door = null
        vehicle = null
    }

    fun dispose() {
        if (!active) return
        active = false
        for ((area, listener) in listeners) guarded { door?.unregisterDoorPosition(area, listener) }
        listeners.clear()
        guarded { gears?.unregisterCallback(gearListener) }
        guarded { car?.disconnect() }
        gears = null
        car = null
        releaseWhenIdle()
    }
}
