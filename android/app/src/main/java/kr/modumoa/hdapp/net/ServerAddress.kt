package kr.modumoa.hdapp.net

import java.net.URI

object ServerAddress {
    fun normalize(value: String): String {
        val address = value.trim().trimEnd('/')
        val uri = try {
            URI(address)
        } catch (_: Exception) {
            throw IllegalArgumentException("서버 주소를 확인해 주세요.")
        }
        require(uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank()) {
            "http:// 또는 https://로 시작하는 서버 주소를 입력해 주세요."
        }
        require(uri.userInfo == null && uri.query == null && uri.fragment == null &&
            (uri.port == -1 || uri.port in 1..65535)) {
            "서버 주소에는 계정 정보·쿼리·조각 식별자를 넣을 수 없습니다. 포트도 확인해 주세요."
        }
        require(uri.scheme == "https" || uri.host in setOf("10.0.2.2", "localhost", "127.0.0.1")) {
            "로컬 개발 서버 외의 주소는 HTTPS를 사용해 주세요."
        }
        return address
    }
}
