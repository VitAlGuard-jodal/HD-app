package kr.modumoa.hdapp.net

data class SseEvent(val name: String, val data: String)

// 안드로이드 의존성이 없는 줄 단위 파서. 미완성 이벤트는 재연결에 넘기지 않는다.
class SseParser {
    private var eventName = "message"
    private val dataLines = mutableListOf<String>()

    fun accept(line: String): SseEvent? {
        if (line.isEmpty()) {
            val event = if (dataLines.isEmpty()) null else SseEvent(eventName, dataLines.joinToString("\n"))
            eventName = "message"
            dataLines.clear()
            return event
        }
        if (line.startsWith(':')) return null
        val separator = line.indexOf(':')
        val field = if (separator < 0) line else line.substring(0, separator)
        val value = if (separator < 0) "" else line.substring(separator + 1).removePrefix(" ")
        when (field) {
            "event" -> eventName = value.ifEmpty { "message" }
            "data" -> dataLines.add(value)
        }
        return null
    }

    companion object {
        fun parse(text: String): List<SseEvent> {
            val parser = SseParser()
            return text.reader().buffered().useLines { lines ->
                lines.mapNotNull(parser::accept).toList()
            }
        }
    }
}
