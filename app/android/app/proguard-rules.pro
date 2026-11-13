# Pleos Vehicle SDK 는 내부에서 Gson TypeToken 으로 응답을 해석한다. R8 이 제네릭 시그니처를 지우면
# 「TypeToken must be created with a type argument」로 문 capability 조회가 실패한다(11/13 에뮬레이터 실측).
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep class ai.pleos.playground.** { *; }
