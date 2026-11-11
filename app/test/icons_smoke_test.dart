import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unavo/ui/icons.dart';

// 실제 SVG 바이트를 동기 번들에 넣어 파일 IO 타이밍과 렌더 검증을 분리한다.
class _IconBundle extends CachingAssetBundle {
  _IconBundle(this.assets);
  final Map<String, ByteData> assets;
  @override
  Future<ByteData> load(String key) => SynchronousFuture(assets[key]!);
}

void main() {
  testWidgets('모든 SVG 아이콘은 첫 진입과 재진입에 불투명 픽셀을 그린다', (tester) async {
    final files = Directory('assets/icons')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.svg'))
        .toList();
    expect(files.length, greaterThanOrEqualTo(27));
    const pending = [
      'location',
      'locationoff',
      'route',
      'navigation',
      'focus',
      'stop',
      'map',
    ];
    final actual = files.map((file) => file.uri.pathSegments.last).toSet();
    final expected = UnavoIcon.names.map((name) => 'ui-$name.svg').toSet();
    expect(actual.difference(expected), isEmpty);
    expect(
      expected
          .difference(actual)
          .difference(pending.map((name) => 'ui-$name.svg').toSet()),
      isEmpty,
    );
    expect(UnavoIcon.names, containsAll(pending));
    final assets = <String, ByteData>{
      for (final file in files)
        file.path: ByteData.sublistView(file.readAsBytesSync()),
    };
    final bundle = _IconBundle(assets);
    svg.cache.clear();
    addTearDown(svg.cache.clear);
    for (var visit = 0; visit < 2; visit++) {
      for (final file in files) {
        final name = file.uri.pathSegments.last
            .substring(3)
            .replaceAll('.svg', '');
        final key = GlobalKey();
        await tester.pumpWidget(
          DefaultAssetBundle(
            bundle: bundle,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Center(
                child: RepaintBoundary(
                  key: key,
                  child: UnavoIcon(name, size: 28),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull, reason: name);
        expect(tester.getSize(find.byType(UnavoIcon)), const Size(28, 28));
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final painted = await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            var pixels = 0;
            for (var i = 3; i < bytes.lengthInBytes; i += 4) {
              if (bytes.getUint8(i) > 32) pixels++;
            }
            return pixels;
          } finally {
            image.dispose();
          }
        });
        expect(painted, greaterThan(8), reason: '$name, visit $visit is blank');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
