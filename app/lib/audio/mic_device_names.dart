class MicDeviceNames {
  static String format(String productName, String address, int id) =>
      '$productName${address.isNotEmpty && address != productName ? ' · $address' : ''}#$id';
}
