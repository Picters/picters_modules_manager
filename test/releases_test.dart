import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/releases_controller.dart';

void main() {
  Map<String, dynamic> release(String channel, String stamp) => {
    'tag_name': '$channel-$stamp',
    'assets': [
      {'name': '$channel-Kernel.zip'},
      {'name': '$channel-OOTMODULES.zip'},
    ],
  };
  test('manual releases notify for either channel', () {
    expect(
      newestManualReleaseCode([release('A16', '20260930-2330')]),
      609302330,
    );
    expect(
      newestManualReleaseCode([
        release('A16', '20260930-2330'),
        release('A17', '20261001-0030'),
      ]),
      610010030,
    );
  });
  test('old formats, missing pairs, drafts and prereleases do not notify', () {
    expect(
      newestManualReleaseCode([
        {'tag_name': 'v1.3.1'},
        {...release('A16', '20260930-2330'), 'draft': true},
        {...release('A17', '20260930-2330'), 'prerelease': true},
        {
          ...release('A16', '20260930-2330'),
          'assets': [
            {'name': 'A17-OOTMODULES.zip'},
          ],
        },
      ]),
      0,
    );
  });
}
