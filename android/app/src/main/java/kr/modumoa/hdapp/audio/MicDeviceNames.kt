package kr.modumoa.hdapp.audio

object MicDeviceNames {
    fun format(productName: String, address: String, id: Int): String = buildString {
        append(productName)
        if (address.isNotEmpty() && address != productName) append(" · ").append(address)
        append('#').append(id)
    }
}
