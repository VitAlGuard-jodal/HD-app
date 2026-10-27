package kr.modumoa.hdapp.auth

object HandleRules {
    private val pattern = Regex("^[a-z0-9_]{3,20}$")

    fun isValid(handle: String): Boolean = pattern.matches(handle)

    const val HELP = "아이디는 소문자 영문·숫자·밑줄로 3~20자 입력해 주세요."
}
