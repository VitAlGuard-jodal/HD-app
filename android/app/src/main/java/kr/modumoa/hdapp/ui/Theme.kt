package kr.modumoa.hdapp.ui

import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsFocusedAsState
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LocalTonalElevationEnabled
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import kr.modumoa.hdapp.R

// style.md의 역할색만 사용한다. 밤·낮 조작부는 같은 48개 슬롯을 공유한다.
private val WesternColorScheme = darkColorScheme(
    primary = Color(0xFFF6AE30), // 금빛 선택·시작
    onPrimary = Color(0xFF0B0F1A), // 금빛 위 패널 기본 잉크
    primaryContainer = Color(0xFFF6AE30), // 금빛 선택
    onPrimaryContainer = Color(0xFF0B0F1A), // 선택 위 잉크
    inversePrimary = Color(0xFFF6AE30), // 반전 면의 금빛 강조
    secondary = Color(0xFFF6AE30), // 금빛 보조 선택
    onSecondary = Color(0xFF0B0F1A), // 보조 선택 위 잉크
    secondaryContainer = Color(0xFFF6AE30), // 금빛 선택 인디케이터
    onSecondaryContainer = Color(0xFF0B0F1A), // 인디케이터 위 잉크
    tertiary = Color(0xFF302D66), // 성운 남색
    onTertiary = Color(0xFFF3EDDF), // 성운 위 본문
    tertiaryContainer = Color(0xFF302D66), // 성운 남색 면
    onTertiaryContainer = Color(0xFFF3EDDF), // 성운 면 위 본문
    background = Color(0xFF0B0F1A), // 패널 기본 잉크
    onBackground = Color(0xFFF3EDDF), // 본문·워드마크
    surface = Color(0xFF0B0F1A), // 패널 기본 잉크
    onSurface = Color(0xFFF3EDDF), // 본문·워드마크
    surfaceVariant = Color(0xFF171E2B), // 입력창·중립 버튼
    onSurfaceVariant = Color(0xFFC0B9AD), // 보조·입력 안내
    surfaceTint = Color(0xFFF6AE30), // 금빛 강조, 고도 합성은 비활성
    inverseSurface = Color(0xFFF3EDDF), // 반전 면의 본문색
    inverseOnSurface = Color(0xFF0B0F1A), // 반전 면 위 잉크
    outline = Color(0xFF818A9C), // 입력 경계
    outlineVariant = Color(0xFF818A9C), // 보조 경계도 동일 대비
    surfaceBright = Color(0xFF171E2B), // 중립 조작 면
    surfaceDim = Color(0xFF0B0F1A), // 패널 기본 잉크
    surfaceContainerLowest = Color(0xFF171E2B), // 입력창·중립 버튼
    surfaceContainerLow = Color(0xFF171E2B), // 중립 조작 면
    surfaceContainer = Color(0xFF171E2B), // 중립 조작 면
    surfaceContainerHigh = Color(0xFF171E2B), // 중립 상태판
    surfaceContainerHighest = Color(0xFF171E2B), // 중립 게이지 바탕
    primaryFixed = Color(0xFFF6AE30), // 고정 금빛 선택
    primaryFixedDim = Color(0xFFF6AE30), // 고정 금빛 선택
    onPrimaryFixed = Color(0xFF0B0F1A), // 고정 선택 위 잉크
    onPrimaryFixedVariant = Color(0xFF0B0F1A), // 고정 선택 위 잉크
    secondaryFixed = Color(0xFFF6AE30), // 고정 금빛 보조 선택
    secondaryFixedDim = Color(0xFFF6AE30), // 고정 금빛 보조 선택
    onSecondaryFixed = Color(0xFF0B0F1A), // 고정 보조 선택 위 잉크
    onSecondaryFixedVariant = Color(0xFF0B0F1A), // 고정 보조 선택 위 잉크
    tertiaryFixed = Color(0xFF302D66), // 고정 성운 남색
    tertiaryFixedDim = Color(0xFF302D66), // 고정 성운 남색
    onTertiaryFixed = Color(0xFFF3EDDF), // 고정 성운 위 본문
    onTertiaryFixedVariant = Color(0xFFF3EDDF), // 고정 성운 위 본문
    error = Color(0xFF73332F), // 끊기·삭제 배경
    onError = Color(0xFFFFB6AB), // 끊기·삭제 전경
    errorContainer = Color(0xFF73332F), // 오류 상태 배경
    onErrorContainer = Color(0xFFFFB6AB), // 오류 상태 전경
    scrim = Color(0xFF0B0F1A), // 패널 기본 잉크 차폐
)

@Immutable
data class ModumoaColors(
    val call: Color = Color(0xFF1D513F),
    val onCall: Color = Color(0xFF9FE3B2),
    val destructive: Color = Color(0xFF73332F),
    val onDestructive: Color = Color(0xFFFFB6AB),
    val panel: Color = Color(0xFF0B0F1A).copy(alpha = 0.92f),
    val panelOpaque: Color = Color(0xFF0B0F1A),
    val accent: Color = Color(0xFFF6AE30),
)

val LocalModumoaColors = staticCompositionLocalOf { ModumoaColors() }
internal val LocalModumoaDarkTheme = staticCompositionLocalOf { true }

// 서체 리소스 참조는 이 파일 한 곳에서 관리한다.
val BlackHanSans = FontFamily(Font(R.font.black_han_sans_regular))
val Rye = FontFamily(Font(R.font.rye_regular))

private val ModumoaShapes = Shapes(
    extraSmall = RoundedCornerShape(4.dp),
    small = RoundedCornerShape(4.dp),
    medium = RoundedCornerShape(4.dp),
    large = RoundedCornerShape(4.dp),
    extraLarge = RoundedCornerShape(0.dp),
)
val ModumoaDeviceShape = RoundedCornerShape(4.dp)

private fun carText(size: Int, height: Int, weight: FontWeight = FontWeight.Normal) = TextStyle(
    fontFamily = FontFamily.SansSerif,
    fontWeight = weight,
    fontSize = size.sp,
    lineHeight = height.sp,
)

private val ModumoaTypography = Typography(
    displayLarge = carText(96, 112).copy(fontFamily = BlackHanSans, letterSpacing = 0.06.em),
    displayMedium = carText(56, 68, FontWeight.Bold),
    displaySmall = carText(44, 56, FontWeight.Bold),
    headlineLarge = carText(40, 52, FontWeight.Bold),
    headlineMedium = carText(34, 44, FontWeight.Bold).copy(letterSpacing = (-0.03).em),
    headlineSmall = carText(28, 38, FontWeight.Bold),
    titleLarge = carText(24, 34, FontWeight.Bold),
    titleMedium = carText(24, 34, FontWeight.Bold),
    titleSmall = carText(20, 28, FontWeight.Bold),
    bodyLarge = carText(24, 34),
    bodyMedium = carText(20, 28),
    bodySmall = carText(20, 28),
    labelLarge = carText(20, 28),
    labelMedium = carText(20, 28),
    labelSmall = carText(20, 28),
)

@Composable
fun ModumoaTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    CompositionLocalProvider(
        LocalModumoaColors provides ModumoaColors(),
        LocalModumoaDarkTheme provides darkTheme,
        LocalTonalElevationEnabled provides false,
    ) {
        MaterialTheme(colorScheme = WesternColorScheme, shapes = ModumoaShapes,
            typography = ModumoaTypography, content = content)
    }
}

@Composable
fun modumoaTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLowest,
    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLowest,
    disabledContainerColor = MaterialTheme.colorScheme.surfaceContainerLowest,
    errorContainerColor = MaterialTheme.colorScheme.surfaceContainerLowest,
    focusedTextColor = MaterialTheme.colorScheme.onSurface,
    unfocusedTextColor = MaterialTheme.colorScheme.onSurface,
    focusedPlaceholderColor = MaterialTheme.colorScheme.onSurfaceVariant,
    unfocusedPlaceholderColor = MaterialTheme.colorScheme.onSurfaceVariant,
    focusedLeadingIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
    unfocusedLeadingIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
    focusedBorderColor = Color.Transparent,
    unfocusedBorderColor = Color.Transparent,
    disabledBorderColor = Color.Transparent,
    errorBorderColor = Color.Transparent,
    disabledTextColor = MaterialTheme.colorScheme.onSurface,
    disabledPlaceholderColor = MaterialTheme.colorScheme.onSurfaceVariant,
    disabledLeadingIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
    disabledSupportingTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
    errorSupportingTextColor = MaterialTheme.colorScheme.onError,
)

// 윤곽 안쪽과 조작부 외곽 사이 6dp를 확보한다. 타깃 크기는 변하지 않는다.
@Composable
fun Modifier.modumoaFocusOutline(focused: Boolean): Modifier {
    val shape = MaterialTheme.shapes.small
    val gold = LocalModumoaColors.current.accent
    return drawWithContent {
        drawContent()
        if (focused) {
            val stroke = 3.dp.toPx()
            val outset = 6.dp.toPx() + stroke / 2f
            val outline = shape.createOutline(
                Size(size.width + 2 * outset, size.height + 2 * outset), layoutDirection, this,
            )
            translate(-outset, -outset) { drawOutline(outline, gold, style = Stroke(stroke)) }
        }
    }
}

@Composable
fun Modifier.modumoaFieldBorder(
    interactionSource: MutableInteractionSource,
    isError: Boolean = false,
): Modifier {
    val focused by interactionSource.collectIsFocusedAsState()
    return border(2.dp, if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.outline,
        MaterialTheme.shapes.small).modumoaFocusOutline(focused)
}
