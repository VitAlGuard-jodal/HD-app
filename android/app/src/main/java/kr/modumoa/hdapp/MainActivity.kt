package kr.modumoa.hdapp

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import kr.modumoa.hdapp.audio.MicScreen
import kr.modumoa.hdapp.auth.AuthScreen
import kr.modumoa.hdapp.call.CallForegroundService
import kr.modumoa.hdapp.contacts.ContactsScreen
import kr.modumoa.hdapp.room.RoomListScreen
import kr.modumoa.hdapp.room.RoomScreen
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.rememberActionState
import kotlinx.coroutines.CancellationException

class MainActivity : ComponentActivity() {
    private var requestedRoom by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestedRoom = intent.getStringExtra(CallForegroundService.EXTRA_ROOM_CODE)
        enableEdgeToEdge()
        val services = (application as HdApp).services
        setContent {
            MaterialTheme {
                Surface(Modifier.fillMaxSize()) {
                    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
                        val session by services.sessionStore.session.collectAsStateWithLifecycle()
                        key(session?.token) {
                            if (session == null) AuthScreen(services) else {
                                HdNavigation(services, requestedRoom, { requestedRoom = null }, {
                                    CallForegroundService.stop(this@MainActivity)
                                    try {
                                        services.rooms.leave()
                                    } catch (cancelled: CancellationException) {
                                        throw cancelled
                                    } catch (_: Exception) { /* 로컬 로그아웃은 서버 접속 여부와 무관하게 진행한다. */ }
                                    try {
                                        services.apiClient.logout()
                                    } finally {
                                        services.rooms.forget()
                                        services.sessionStore.clear()
                                    }
                                })
                            }
                        }
                    }
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        requestedRoom = intent.getStringExtra(CallForegroundService.EXTRA_ROOM_CODE)
    }
}

@Composable
private fun HdNavigation(
    services: ServiceLocator,
    requestedRoom: String?,
    onRequestConsumed: () -> Unit,
    onLogout: suspend () -> Unit,
) {
    val nav = rememberNavController()
    val backStack by nav.currentBackStackEntryAsState()
    val action = rememberActionState()
    val openRoom: (String) -> Unit = { code ->
        nav.navigate("room/${Uri.encode(code)}") { popUpTo("rooms"); launchSingleTop = true }
    }
    LaunchedEffect(requestedRoom) {
        if (requestedRoom != null) {
            if (services.rooms.state.value.code == requestedRoom) openRoom(requestedRoom)
            onRequestConsumed()
        }
    }
    Column(Modifier.fillMaxSize()) {
        Text("모두모아 · @${services.sessionStore.handle.orEmpty()}", Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
        Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())) {
            TextButton(enabled = !action.busy, onClick = { nav.popBackStack("rooms", false) }) { Text("방 목록") }
            TextButton(enabled = !action.busy, onClick = {
                nav.navigate("contacts") { launchSingleTop = true }
            }) { Text("친구") }
            TextButton(enabled = !action.busy, onClick = {
                nav.navigate("mic") { launchSingleTop = true }
            }) { Text("마이크") }
            TextButton(enabled = !action.busy, onClick = { action.run { onLogout() } }) {
                Text(if (action.busy) "로그아웃 중…" else "로그아웃")
            }
        }
        if (backStack?.destination?.route != "rooms") {
            TextButton(onClick = { nav.popBackStack() }) { Text("뒤로") }
        }
        ErrorText(action.error)
        HorizontalDivider()
        NavHost(navController = nav, startDestination = "rooms", modifier = Modifier.weight(1f)) {
            composable("rooms") { RoomListScreen(services, openRoom) }
            composable("contacts") { ContactsScreen(services, openRoom) }
            composable("mic") { MicScreen(services.micRouter) }
            composable("room/{code}") { entry ->
                val code = entry.arguments?.getString("code") ?: return@composable
                RoomScreen(code, services, { nav.popBackStack("rooms", false) }, {
                    nav.navigate("mic") { launchSingleTop = true }
                })
            }
        }
    }
}
