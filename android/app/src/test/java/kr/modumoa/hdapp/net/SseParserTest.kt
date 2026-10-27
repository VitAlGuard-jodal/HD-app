package kr.modumoa.hdapp.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SseParserTest {
    @Test
    fun parsesNamedEventsAndIgnoresPing() {
        val events = SseParser.parse("event: hello\ndata: {\"self\":\"driver_1\"}\n\n: ping\n\nevent: member-joined\ndata: {\"handle\":\"friend_2\"}\n\n")
        assertEquals(listOf(
            SseEvent("hello", "{\"self\":\"driver_1\"}"),
            SseEvent("member-joined", "{\"handle\":\"friend_2\"}"),
        ), events)
    }

    @Test
    fun joinsMultipleDataLinesWithNewline() {
        val events = SseParser.parse("event: signal\ndata: {\ndata:  \"kind\": \"ice\"\ndata: }\n\n")
        assertEquals(SseEvent("signal", "{\n \"kind\": \"ice\"\n}"), events.single())
    }

    @Test
    fun defaultsNameAndResetsAfterEachEvent() {
        val events = SseParser.parse("event: hello\ndata: {}\n\ndata: {}\n\n")
        assertEquals(listOf("hello", "message"), events.map { it.name })
    }

    @Test
    fun supportsCrLfUnknownFieldsAndEmptyData() {
        val events = SseParser.parse("id: 1\r\nretry: 500\r\ndata:\r\n\r\n")
        assertEquals(listOf(SseEvent("message", "")), events)
    }

    @Test
    fun discardsIncompleteEventAtEof() {
        assertTrue(SseParser.parse("event: signal\ndata: {\"partial\":true}\n").isEmpty())
        assertTrue(SseParser.parse(": ping\n\nevent: hello\n\n").isEmpty())
    }

    @Test
    fun preservesColonsAndStripsOnlyOneLeadingSpace() {
        val parser = SseParser()
        assertNull(parser.accept("event: signal"))
        assertNull(parser.accept("data:  {\"url\":\"https://example.test\"}"))
        assertEquals(SseEvent("signal", " {\"url\":\"https://example.test\"}"), parser.accept(""))
    }
}
