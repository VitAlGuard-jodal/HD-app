package kr.modumoa.hdapp.auth

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HandleRulesTest {
    @Test
    fun acceptsLowercaseDigitsAndUnderscores() {
        listOf("abc", "driver_01", "123", "___", "a".repeat(20)).forEach {
            assertTrue(it, HandleRules.isValid(it))
        }
    }

    @Test
    fun rejectsOutsideLengthBounds() {
        listOf("", "ab", "a".repeat(21)).forEach { assertFalse(it, HandleRules.isValid(it)) }
    }

    @Test
    fun rejectsUppercaseWhitespaceAndOtherCharacters() {
        listOf("ABC", "a b", "user-name", "user.name", "사용자", "abc\n", " abc", "abc ", "abc@x").forEach {
            assertFalse(it, HandleRules.isValid(it))
        }
    }
}
