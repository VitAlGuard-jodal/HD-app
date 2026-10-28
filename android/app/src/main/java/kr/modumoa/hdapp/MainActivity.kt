package kr.modumoa.hdapp

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.Contacts
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.CancellationException
import kr.modumoa.hdapp.audio.MicScreen
import kr.modumoa.hdapp.auth.AuthScreen
import kr.modumoa.hdapp.call.CallForegroundService
import kr.modumoa.hdapp.contacts.ContactsScreen
import kr.modumoa.hdapp.room.RoomListScreen
import kr.modumoa.hdapp.room.RoomScreen
import kr.modumoa.hdapp.ui.CarButtonStyle
import kr.modumoa.hdapp.ui.CarIconButton
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.LocalModumoaColors
import kr.modumoa.hdapp.ui.ModumoaBackdrop
import kr.modumoa.hdapp.ui.ModumoaTheme
import kr.modumoa.hdapp.ui.MotionFast
import kr.modumoa.hdapp.ui.MotionNormal
import kr.modumoa.hdapp.ui.WesternFooter
import kr.modumoa.hdapp.ui.WesternHeader
import kr.modumoa.hdapp.ui.motionTween
import kr.modumoa.hdapp.ui.rememberActionState

class MainActivity : ComponentActivity() {
    private var requestedRoom by mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestedRoom = intent.getStringExtra(CallForegroundService.EXTRA_ROOM_CODE)
        // 낮 배경에서도 잉크 조작부와 같은 밝은 시스템 아이콘을 유지한다.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        val services = (application as HdApp).services
        setContent {
            ModumoaTheme {
                ModumoaBackdrop {
                    val session by services.sessionStore.session.collectAsStateWithLifecycle()
                    key(session?.token) {
                        if (session == null) {
                            Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
                                WesternHeader {
                                    Text("여러 차, 하나의 목소리", style = MaterialTheme.typography.bodyMedium)
                                }
                                Box(Modifier.weight(1f)) { AuthScreen(services) }
                                WesternFooter()
                            }
                        } else {
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
    val route = backStack?.destination?.route
    Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
        WesternHeader {
            Text("@${services.sessionStore.handle.orEmpty()}", Modifier.weight(1f, fill = false),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (route != "rooms") {
                CarIconButton(Icons.AutoMirrored.Filled.ArrowBack, "뒤로", onClick = { nav.popBackStack() })
            }
            CarIconButton(Icons.AutoMirrored.Filled.Logout, "로그아웃",
                enabled = !action.busy, busy = action.busy, onClick = { action.run { onLogout() } })
        }
        Surface(color = LocalModumoaColors.current.panel) { ErrorText(action.error) }
        NavHost(
            navController = nav, startDestination = "rooms", modifier = Modifier.weight(1f),
            enterTransition = {
                fadeIn(motionTween(MotionNormal)) + slideInHorizontally(motionTween(MotionNormal)) { it / 8 }
            },
            exitTransition = { fadeOut(motionTween(MotionFast)) },
            popEnterTransition = {
                fadeIn(motionTween(MotionNormal)) + slideInHorizontally(motionTween(MotionNormal)) { -it / 8 }
            },
            popExitTransition = {
                fadeOut(motionTween(MotionFast)) + slideOutHorizontally(motionTween(MotionFast)) { it / 8 }
            },
        ) {
            composable("rooms") { RoomListScreen(services, openRoom) }
            composable("contacts") { ContactsScreen(services, openRoom) }
            composable("mic") { MicScreen(services) }
            composable("room/{code}") { entry ->
                val code = entry.arguments?.getString("code") ?: return@composable
                RoomScreen(code, services, { nav.popBackStack("rooms", false) }, {
                    nav.navigate("mic") { launchSingleTop = true }
                })
            }
        }
        WesternFooter {
            val roomsSelected = route == "rooms" || route == "room/{code}"
            CarIconButton(Icons.Filled.Groups, "통화 방", enabled = !action.busy,
                modifier = Modifier.semantics { selected = roomsSelected },
                style = if (roomsSelected) CarButtonStyle.Filled else CarButtonStyle.Tonal,
                onClick = { nav.popBackStack("rooms", false) })
            CarIconButton(Icons.Filled.Contacts, "친구", enabled = !action.busy,
                modifier = Modifier.semantics { selected = route == "contacts" },
                style = if (route == "contacts") CarButtonStyle.Filled else CarButtonStyle.Tonal,
                onClick = { nav.navigate("contacts") { launchSingleTop = true } })
            CarIconButton(Icons.Filled.Mic, "마이크", enabled = !action.busy,
                modifier = Modifier.semantics { selected = route == "mic" },
                style = if (route == "mic") CarButtonStyle.Filled else CarButtonStyle.Tonal,
                onClick = { nav.navigate("mic") { launchSingleTop = true } })
        }
    }
}
