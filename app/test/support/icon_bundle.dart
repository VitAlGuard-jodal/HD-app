import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 동작/레이아웃 테스트는 Fable이 별도로 공급하는 SVG 파일을 요구하지 않는다.
/// 실제 아이콘 픽셀 검증은 icons_smoke_test에서만 한다.
class TestIconBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) => key.startsWith('assets/icons/')
      ? SynchronousFuture(
          ByteData.sublistView(
            Uint8List.fromList(
              utf8.encode(
                '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24">'
                '<path d="M4 4H20V20H4Z" fill="#fff"/></svg>',
              ),
            ),
          ),
        )
      : rootBundle.load(key);
}

final _icons = TestIconBundle();
Widget testIconBuilder(BuildContext context, Widget? child) =>
    DefaultAssetBundle(bundle: _icons, child: child ?? const SizedBox.shrink());
