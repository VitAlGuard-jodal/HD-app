package kr.modumoa.hdapp

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Logout
import androidx.compose.material.icons.filled.Contacts
import androidx.compose.material.icons.filled.Groups
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
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
import kr.modumoa.hdapp.ui.CarGap
import kr.modumoa.hdapp.ui.CarIconButton
import kr.modumoa.hdapp.ui.CarTouchTarget
import kr.modumoa.hdapp.ui.ErrorText
import kr.modumoa.hdapp.ui.IconSecondary
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
                    val session by services.sessionStore.session.collectAsStateWithLifecycle()
                    key(session?.token) {
                        if (session == null) {
                            Column(Modifier.fillMaxSize().safeDrawingPadding().imePadding()) {
                                AuthScreen(services)
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

@OptIn(ExperimentalMaterial3Api::class)
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
    Scaffold(
        modifier = Modifier.fillMaxSize().imePadding(),
        contentWindowInsets = WindowInsets.safeDrawing,
        topBar = {
            TopAppBar(
                title = { Text("@${services.sessionStore.handle.orEmpty()}") },
                expandedHeight = CarTouchTarget,
                windowInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Top),
                navigationIcon = {
                    if (route != "rooms") {
                        CarIconButton(Icons.AutoMirrored.Filled.ArrowBack, "뒤로", onClick = { nav.popBackStack() })
                    }
                },
                actions = {
                    CarIconButton(Icons.AutoMirrored.Filled.Logout, "로그아웃",
                        enabled = !action.busy, busy = action.busy, onClick = { action.run { onLogout() } })
                },
            )
        },
        bottomBar = {
            NavigationBar(windowInsets = WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)) {
                NavigationBarItem(
                    selected = route == "rooms" || route == "room/{code}",
                    onClick = { nav.popBackStack("rooms", false) },
                    icon = { Icon(Icons.Filled.Groups, "통화 방", Modifier.size(IconSecondary)) },
                    modifier = Modifier.height(CarTouchTarget),
                    label = null, alwaysShowLabel = false, enabled = !action.busy,
                )
                Spacer(Modifier.width(CarGap))
                NavigationBarItem(
                    selected = route == "contacts",
                    onClick = { nav.navigate("contacts") { launchSingleTop = true } },
                    icon = { Icon(Icons.Filled.Contacts, "친구", Modifier.size(IconSecondary)) },
                    modifier = Modifier.height(CarTouchTarget),
                    label = null, alwaysShowLabel = false, enabled = !action.busy,
                )
                Spacer(Modifier.width(CarGap))
                NavigationBarItem(
                    selected = route == "mic",
                    onClick = { nav.navigate("mic") { launchSingleTop = true } },
                    icon = { Icon(Icons.Filled.Mic, "마이크", Modifier.size(IconSecondary)) },
                    modifier = Modifier.height(CarTouchTarget),
                    label = null, alwaysShowLabel = false, enabled = !action.busy,
                )
            }
        },
    ) { innerPadding ->
        Column(Modifier.fillMaxSize().padding(innerPadding).consumeWindowInsets(innerPadding)) {
            ErrorText(action.error)
            NavHost(navController = nav, startDestination = "rooms", modifier = Modifier.weight(1f)) {
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
        }
    }
}
