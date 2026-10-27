package kr.modumoa.hdapp.net

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

class ApiClient(
    private val baseUrlProvider: () -> String,
    private val tokenProvider: () -> String?,
) {
    suspend fun signup(handle: String, password: String, displayName: String): AuthResult =
        auth("/v1/auth/signup", JSONObject().put("handle", handle).put("password", password)
            .put("displayName", displayName))

    suspend fun login(handle: String, password: String): AuthResult =
        auth("/v1/auth/login", JSONObject().put("handle", handle).put("password", password))

    suspend fun logout() { request("POST", "/v1/auth/logout") }

    suspend fun me(): User = user(response("GET", "/v1/me").getJSONObject("user"))

    suspend fun getUser(handle: String): User =
        user(response("GET", "/v1/users/${segment(handle)}").getJSONObject("user"))

    suspend fun listContacts(): List<User> {
        val contacts = response("GET", "/v1/contacts").getJSONArray("contacts")
        return List(contacts.length()) { user(contacts.getJSONObject(it)) }
    }

    suspend fun addContact(handle: String): User = user(
        response("POST", "/v1/contacts", JSONObject().put("handle", handle)).getJSONObject("contact"),
    )

    suspend fun removeContact(handle: String) { request("DELETE", "/v1/contacts/${segment(handle)}") }

    suspend fun createRoom(name: String? = null, invitees: List<String> = emptyList()): Room {
        val body = JSONObject()
        name?.takeIf { it.isNotBlank() }?.let { body.put("name", it) }
        if (invitees.isNotEmpty()) body.put("invitees", JSONArray(invitees))
        return room(response("POST", "/v1/rooms", body).getJSONObject("room"))
    }

    suspend fun getRoom(code: String): RoomDetails {
        val result = response("GET", "/v1/rooms/${segment(code)}")
        val members = result.getJSONArray("members")
        return RoomDetails(room(result.getJSONObject("room")), List(members.length()) {
            val member = members.getJSONObject(it)
            Member(member.getString("handle"), member.getString("displayName"), member.optString("joinedAt"))
        })
    }

    suspend fun joinRoom(code: String): Room =
        room(response("POST", "/v1/rooms/${segment(code)}/join").getJSONObject("room"))

    suspend fun leaveRoom(code: String) { request("POST", "/v1/rooms/${segment(code)}/leave") }

    suspend fun sendSignal(code: String, to: String, kind: String, payload: Any?) {
        require(kind in setOf("offer", "answer", "ice", "custom")) { "지원하지 않는 시그널 종류입니다." }
        request("POST", "/v1/rooms/${segment(code)}/signal", JSONObject()
            .put("to", to).put("kind", kind).put("payload", payload ?: JSONObject.NULL))
    }

    fun subscribeEvents(code: String): Flow<RoomEvent> = channelFlow {
        val currentConnection = AtomicReference<HttpURLConnection?>(null)
        val reader = launch(Dispatchers.IO) {
            var wasConnected = false
            var backoff = 2_000L
            while (isActive) {
                var connection: HttpURLConnection? = null
                var connectedAt = 0L
                try {
                    connection = open("GET", "/v1/rooms/${segment(code)}/events")
                    currentConnection.set(connection)
                    currentCoroutineContext().ensureActive()
                    connection.readTimeout = 35_000
                    connection.setRequestProperty("Accept", "text/event-stream")
                    connection.setRequestProperty("Cache-Control", "no-cache")
                    val status = connection.responseCode
                    if (status !in 200..299) throw responseError(connection, status)
                    connectedAt = System.nanoTime()
                    if (wasConnected) send(RoomEvent.Reconnected)
                    wasConnected = true
                    val parser = SseParser()
                    connection.inputStream.bufferedReader(Charsets.UTF_8).use { input ->
                        while (isActive) {
                            val line = input.readLine() ?: break
                            val event = parser.accept(line) ?: continue
                            decode(event)?.let { send(it) }
                        }
                    }
                    throw IOException("서버 연결이 끊겼습니다.")
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    currentCoroutineContext().ensureActive()
                    // 인증 실패와 사라진 방은 자동 재시도로 복구되지 않는다.
                    if (error is ApiException && error.status in setOf(401, 403, 404)) {
                        close(error)
                        return@launch
                    }
                    if (connectedAt != 0L && System.nanoTime() - connectedAt >= 15_000_000_000L) {
                        backoff = 2_000L
                    }
                    send(RoomEvent.Disconnected("연결을 다시 시도합니다.", backoff))
                } finally {
                    currentConnection.compareAndSet(connection, null)
                    connection?.disconnect()
                }
                delay(backoff)
                backoff = (backoff * 2).coerceAtMost(30_000L)
            }
        }
        // 블로킹 readLine도 구독 취소 시 소켓을 닫아 해제한다.
        awaitClose {
            reader.cancel()
            currentConnection.getAndSet(null)?.disconnect()
        }
    }.flowOn(Dispatchers.IO)

    private suspend fun auth(path: String, body: JSONObject): AuthResult {
        val result = response("POST", path, body)
        return AuthResult(user(result.getJSONObject("user")), result.getString("token"))
    }

    private suspend fun response(method: String, path: String, body: JSONObject? = null): JSONObject =
        request(method, path, body) ?: throw ApiException(0, "empty_response", "서버 응답이 비어 있습니다.")

    private suspend fun request(method: String, path: String, body: JSONObject? = null): JSONObject? =
        withContext(Dispatchers.IO) {
            val connection = open(method, path)
            try {
                if (body != null) {
                    connection.doOutput = true
                    connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                    connection.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                }
                val status = connection.responseCode
                if (status !in 200..299) throw responseError(connection, status)
                val text = if (status == 204) "" else connection.inputStream.bufferedReader(Charsets.UTF_8)
                    .use { it.readText() }
                currentCoroutineContext().ensureActive()
                if (text.isBlank()) null else try {
                    JSONObject(text)
                } catch (_: JSONException) {
                    throw ApiException(status, "invalid_response", "서버 응답 형식을 확인해 주세요.")
                }
            } finally {
                connection.disconnect()
            }
        }

    private fun open(method: String, path: String): HttpURLConnection =
        (URL(ServerAddress.normalize(baseUrlProvider()) + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 15_000
            readTimeout = 15_000
            instanceFollowRedirects = false
            useCaches = false
            setRequestProperty("Accept", "application/json")
            tokenProvider()?.let { setRequestProperty("Authorization", "Bearer $it") }
        }

    private fun responseError(connection: HttpURLConnection, status: Int): ApiException {
        val text = connection.errorStream?.bufferedReader(Charsets.UTF_8)?.use { it.readText() }.orEmpty()
        val json = try { JSONObject(text) } catch (_: JSONException) { null }
        val error = json?.optJSONObject("error") ?: json
        val message = error?.optString("message")?.takeIf { it.isNotBlank() }
            ?: (json?.opt("error") as? String)?.takeIf { it.isNotBlank() }
            ?: "서버 요청에 실패했습니다. (HTTP $status)"
        return ApiException(status, error?.optString("code")?.takeIf { it.isNotBlank() } ?: "http_$status", message)
    }

    private fun decode(event: SseEvent): RoomEvent? {
        if (event.name !in setOf("hello", "member-joined", "member-left", "signal")) return null
        val data = JSONObject(event.data)
        return when (event.name) {
            "hello" -> RoomEvent.Hello(data.optJSONObject("self")?.optString("handle") ?: data.optString("self"))
            "member-joined" -> RoomEvent.MemberJoined(data.getString("handle"))
            "member-left" -> RoomEvent.MemberLeft(data.getString("handle"))
            "signal" -> RoomEvent.Signal(data.getString("from"), data.getString("kind"),
                data.opt("payload").takeUnless { it == JSONObject.NULL })
            else -> null
        }
    }

    private fun user(json: JSONObject) = User(json.getString("handle"), json.getString("displayName"))
    private fun room(json: JSONObject) = Room(json.getString("code"), json.optString("name").takeIf { it.isNotBlank() })
    private fun segment(value: String): String = URLEncoder.encode(value, "UTF-8").replace("+", "%20")
}
