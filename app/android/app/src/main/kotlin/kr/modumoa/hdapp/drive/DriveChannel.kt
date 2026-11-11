package kr.modumoa.hdapp.drive

import android.car.Car
import android.car.drivingstate.CarUxRestrictions
import android.car.drivingstate.CarUxRestrictionsManager
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel

class DriveChannel(context: Context, messenger: BinaryMessenger) : EventChannel.StreamHandler {
    private val context = context.applicationContext
    private val events = EventChannel(messenger, "unavo/drive")
    private var currentSink: EventChannel.EventSink? = null
    private var stopListening: (() -> Unit)? = null

    init { events.setStreamHandler(this) }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        onCancel(null)
        currentSink = sink
        try {
            if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)) {
                unavailable(sink)
                return
            }
            Class.forName("android.car.Car")
            val subscription = AutomotiveUxSubscription(context)
            // start 중 실패해도 이미 연결한 Car와 리스너를 정리한다.
            stopListening = subscription::dispose
            subscription.start { restricted, activeRestrictions ->
                if (currentSink === sink) {
                    sink.success(mapOf(
                        "restricted" to restricted,
                        "activeRestrictions" to activeRestrictions,
                        "available" to true,
                    ))
                }
            }
        } catch (_: Exception) {
            unavailable(sink)
        } catch (_: LinkageError) {
            // android.car는 폰에 없는 선택 라이브러리다.
            unavailable(sink)
        }
    }

    private fun unavailable(sink: EventChannel.EventSink) {
        onCancel(null)
        sink.success(mapOf("restricted" to false, "available" to false))
        sink.endOfStream()
    }

    override fun onCancel(arguments: Any?) {
        currentSink = null
        val stop = stopListening
        stopListening = null
        stop?.invoke()
    }

    fun dispose() {
        onCancel(null)
        events.setStreamHandler(null)
    }
}

// DriveChannel 자체에는 Car 타입의 필드/메서드가 없다. 폰에서는 이 클래스를
// 생성하지 않아 android.car가 없어도 채널 등록과 구독 해제가 가능하다.
private class AutomotiveUxSubscription(private val context: Context) {
    private var car: Car? = null
    private var manager: CarUxRestrictionsManager? = null

    fun start(emit: (Boolean, Int) -> Unit) {
        val connectedCar = checkNotNull(Car.createCar(context))
        car = connectedCar
        check(connectedCar.isConnected)
        val restrictionsManager = connectedCar.getCarManager(Car.CAR_UX_RESTRICTION_SERVICE)
            as CarUxRestrictionsManager
        manager = restrictionsManager
        fun publish(restrictions: CarUxRestrictions) {
            emit(restrictions.isRequiresDistractionOptimization, restrictions.activeRestrictions)
        }
        restrictionsManager.registerListener { restrictions -> publish(restrictions) }
        publish(checkNotNull(restrictionsManager.currentCarUxRestrictions))
    }

    fun dispose() {
        try {
            manager?.unregisterListener()
        } catch (_: Exception) {
            // 서비스가 끊겼어도 나머지 자원을 해제한다.
        } catch (_: LinkageError) {
            // 선택 라이브러리의 연결 오류도 해제를 막지 않는다.
        } finally {
            manager = null
            try {
                car?.disconnect()
            } catch (_: Exception) {
                // 이미 끊긴 Car도 로컬 참조는 정리한다.
            } catch (_: LinkageError) {
                // 선택 라이브러리의 연결 오류도 해제를 막지 않는다.
            } finally {
                car = null
            }
        }
    }
}
