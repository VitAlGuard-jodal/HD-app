package kr.modumoa.hdapp.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LocalTonalElevationEnabled
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// 디자인 정본 §5의 A 낮·A 밤 전체 슬롯을 명시한다. 동적 색상은 사용하지 않는다.
private val LightColorScheme = lightColorScheme(
    primary = Color(0xFF8A351C),
    onPrimary = Color(0xFFFFF8EC),
    primaryContainer = Color(0xFFFFD1AC),
    onPrimaryContainer = Color(0xFF4F220F),
    inversePrimary = Color(0xFFFFB78D),
    secondary = Color(0xFF4B5C24),
    onSecondary = Color(0xFFFFFFFF),
    secondaryContainer = Color(0xFFDCE7B0),
    onSecondaryContainer = Color(0xFF273411),
    tertiary = Color(0xFF1B596F),
    onTertiary = Color(0xFFFFFFFF),
    tertiaryContainer = Color(0xFFC8E9F3),
    onTertiaryContainer = Color(0xFF173843),
    surface = Color(0xFFFFF4DD),
    onSurface = Color(0xFF292E25),
    surfaceVariant = Color(0xFFEAE3CF),
    onSurfaceVariant = Color(0xFF535B4B),
    outline = Color(0xFF565D4C),
    outlineVariant = Color(0xFF565D4C),
    inverseSurface = Color(0xFF30382D),
    inverseOnSurface = Color(0xFFF6EFDF),
    surfaceBright = Color(0xFFFFFBF2),
    surfaceDim = Color(0xFFDED7C4),
    surfaceContainerLowest = Color(0xFFFFFCF6),
    surfaceContainerLow = Color(0xFFFAECD2),
    surfaceContainer = Color(0xFFF2E6CC),
    surfaceContainerHigh = Color(0xFFEEE0C4),
    surfaceContainerHighest = Color(0xFFE6DCC5),
    primaryFixed = Color(0xFFFFD1AC),
    primaryFixedDim = Color(0xFFFFB78D),
    onPrimaryFixed = Color(0xFF4F220F),
    onPrimaryFixedVariant = Color(0xFF723119),
    secondaryFixed = Color(0xFFDCE7B0),
    secondaryFixedDim = Color(0xFFC2D67F),
    onSecondaryFixed = Color(0xFF273411),
    onSecondaryFixedVariant = Color(0xFF41511E),
    tertiaryFixed = Color(0xFFC8E9F3),
    tertiaryFixedDim = Color(0xFF93D0DD),
    onTertiaryFixed = Color(0xFF173843),
    onTertiaryFixedVariant = Color(0xFF225364),
    error = Color(0xFFB12C32),
    onError = Color(0xFFFFFFFF),
    errorContainer = Color(0xFFFFDADB),
    onErrorContainer = Color(0xFF68151D),
    scrim = Color(0xFF000000),
    background = Color(0xFFFFF4DD),
    onBackground = Color(0xFF292E25),
    surfaceTint = Color(0xFF8A351C),
)

private val DarkColorScheme = darkColorScheme(
    primary = Color(0xFFF4C16E),
    onPrimary = Color(0xFF35250C),
    primaryContainer = Color(0xFF4D391D),
    onPrimaryContainer = Color(0xFFFFE4AF),
    inversePrimary = Color(0xFF8A351C),
    secondary = Color(0xFFD2DF88),
    onSecondary = Color(0xFF2B3612),
    secondaryContainer = Color(0xFF3B4925),
    onSecondaryContainer = Color(0xFFE4EDBC),
    tertiary = Color(0xFF93D0DD),
    onTertiary = Color(0xFF10343D),
    tertiaryContainer = Color(0xFF234B53),
    onTertiaryContainer = Color(0xFFC6EBF2),
    surface = Color(0xFF101820),
    onSurface = Color(0xFFF4EBD8),
    surfaceVariant = Color(0xFF273B46),
    onSurfaceVariant = Color(0xFFD1CEC3),
    outline = Color(0xFFBCC8CB),
    outlineVariant = Color(0xFFBCC8CB),
    inverseSurface = Color(0xFFF4EBD8),
    inverseOnSurface = Color(0xFF292E25),
    surfaceBright = Color(0xFF293642),
    surfaceDim = Color(0xFF0B1118),
    surfaceContainerLowest = Color(0xFF0B1118),
    surfaceContainerLow = Color(0xFF15212C),
    surfaceContainer = Color(0xFF1B2A36),
    surfaceContainerHigh = Color(0xFF223340),
    surfaceContainerHighest = Color(0xFF293C49),
    primaryFixed = Color(0xFFFFD1AC),
    primaryFixedDim = Color(0xFFFFB78D),
    onPrimaryFixed = Color(0xFF4F220F),
    onPrimaryFixedVariant = Color(0xFF723119),
    secondaryFixed = Color(0xFFDCE7B0),
    secondaryFixedDim = Color(0xFFC2D67F),
    onSecondaryFixed = Color(0xFF273411),
    onSecondaryFixedVariant = Color(0xFF41511E),
    tertiaryFixed = Color(0xFFC8E9F3),
    tertiaryFixedDim = Color(0xFF93D0DD),
    onTertiaryFixed = Color(0xFF173843),
    onTertiaryFixedVariant = Color(0xFF225364),
    error = Color(0xFFFF9C98),
    onError = Color(0xFF4C1118),
    errorContainer = Color(0xFF57272A),
    onErrorContainer = Color(0xFFFFDADB),
    scrim = Color(0xFF000000),
    background = Color(0xFF101820),
    onBackground = Color(0xFFF4EBD8),
    surfaceTint = Color(0xFFF4C16E),
)

// 통화·종료·경고와 장식 팔레트는 역할을 섞지 않고 별도로 제공한다.
@Immutable
data class ModumoaColors(
    val call: Color,
    val onCall: Color,
    val callContainer: Color,
    val onCallContainer: Color,
    val warning: Color,
    val warningContainer: Color,
    val destructive: Color,
    val onDestructive: Color,
    val artBase: Color,
    val artPink: Color,
    val artPeach: Color,
    val artYellow: Color,
    val artLime: Color,
    val artBlue: Color,
    val artWhite: Color,
    val artInk: Color,
)

private val LightModumoaColors = ModumoaColors(
    call = Color(0xFF21633B),
    onCall = Color(0xFFFFFFFF),
    callContainer = Color(0xFFD5EED9),
    onCallContainer = Color(0xFF174B29),
    warning = Color(0xFF715012),
    warningContainer = Color(0xFFFFF0BD),
    destructive = Color(0xFFB12C32),
    onDestructive = Color(0xFFFFFFFF),
    artBase = Color(0xFFF8DEB3),
    artPink = Color(0xFFEFA4A0),
    artPeach = Color(0xFFF3B27E),
    artYellow = Color(0xFFEAB33D),
    artLime = Color(0xFFCBDD65),
    artBlue = Color(0xFF80B5BF),
    artWhite = Color(0xFFFFF5DD),
    artInk = Color(0xFF273329),
)

private val DarkModumoaColors = ModumoaColors(
    call = Color(0xFF80D79B),
    onCall = Color(0xFF10351C),
    callContainer = Color(0xFF203E2B),
    onCallContainer = Color(0xFFBFECC7),
    warning = Color(0xFFFFE3A0),
    warningContainer = Color(0xFF4C3C14),
    destructive = Color(0xFFFF9C98),
    onDestructive = Color(0xFF4C1118),
    artBase = Color(0xFFD6B98D),
    artPink = Color(0xFFD29A9F),
    artPeach = Color(0xFFD9A16F),
    artYellow = Color(0xFFD5AE55),
    artLime = Color(0xFFB6C66B),
    artBlue = Color(0xFF89AEB4),
    artWhite = Color(0xFFE8DDC4),
    artInk = Color(0xFF15222D),
)

val LocalModumoaColors = staticCompositionLocalOf { LightModumoaColors }

private val ModumoaShapes = Shapes(
    extraSmall = RoundedCornerShape(4.dp),
    small = RoundedCornerShape(16.dp),
    medium = RoundedCornerShape(24.dp),
    large = RoundedCornerShape(28.dp),
    extraLarge = RoundedCornerShape(36.dp),
)
val ModumoaDeviceShape = RoundedCornerShape(26.dp)

private fun carText(size: Int, height: Int, weight: FontWeight = FontWeight.Bold) = TextStyle(
    fontFamily = FontFamily.SansSerif,
    fontWeight = weight,
    fontSize = size.sp,
    lineHeight = height.sp,
)

private val ModumoaTypography = Typography(
    displayLarge = carText(128, 154, FontWeight.Black).copy(
        fontFeatureSettings = "tnum", letterSpacing = 5.76.sp,
    ),
    displayMedium = carText(100, 140, FontWeight.Black).copy(
        fontFeatureSettings = "tnum", letterSpacing = 4.5.sp,
    ),
    displaySmall = carText(44, 62),
    headlineLarge = carText(39, 55, FontWeight.Black),
    headlineMedium = carText(36, 50),
    headlineSmall = carText(32, 45),
    titleLarge = carText(30, 42),
    titleMedium = carText(28, 39),
    titleSmall = carText(24, 34),
    bodyLarge = carText(28, 39),
    bodyMedium = carText(24, 34),
    bodySmall = carText(24, 30),
    labelLarge = carText(28, 39),
    labelMedium = carText(24, 30),
    labelSmall = carText(20, 24),
)

@Composable
fun ModumoaTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    CompositionLocalProvider(
        LocalModumoaColors provides if (darkTheme) DarkModumoaColors else LightModumoaColors,
        // 확정된 면 색상이 고도에 따른 자동 합성으로 달라지지 않게 한다.
        LocalTonalElevationEnabled provides false,
    ) {
        MaterialTheme(
            colorScheme = if (darkTheme) DarkColorScheme else LightColorScheme,
            shapes = ModumoaShapes,
            typography = ModumoaTypography,
            content = content,
        )
    }
}

@Composable
fun modumoaTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLowest,
    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLowest,
    disabledContainerColor = MaterialTheme.colorScheme.surfaceContainerLowest,
    errorContainerColor = MaterialTheme.colorScheme.surfaceContainerLowest,
    focusedBorderColor = Color.Transparent,
    unfocusedBorderColor = Color.Transparent,
    disabledBorderColor = Color.Transparent,
    errorBorderColor = Color.Transparent,
    disabledTextColor = MaterialTheme.colorScheme.onSurface,
    disabledPlaceholderColor = MaterialTheme.colorScheme.onSurfaceVariant,
    disabledLeadingIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
    disabledSupportingTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
)

// 포커스·비활성 여부와 무관하게 2dp를 유지하고 오류일 때만 오류색을 쓴다.
@Composable
fun Modifier.modumoaFieldBorder(isError: Boolean = false): Modifier = border(
    width = 2.dp,
    color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.outline,
    shape = MaterialTheme.shapes.medium,
)
