import 'package:flutter_test/flutter_test.dart';
import 'package:picters_modules_manager/releases_controller.dart';

void main() {
  Map<String, dynamic> release(
    String channel,
    String stamp, {
    String packPrefix = 'Mi17_SystemPack',
  }) => {
    'tag_name': '$channel-$stamp',
    'assets': [
      {
        'name':
            'Mi17_Kernel-6.12.23-android${channel.substring(1)}-picters-ReSuki-g123-susfs-$stamp.zip',
      },
      {
        'name':
            '$packPrefix-6.12.23-android${channel.substring(1)}-picters-ReSuki-g123-susfs-$stamp.zip',
      },
    ],
  };
  test('BakaSU combined release keeps matching manual packages', () {
    final item = release(
      'A17',
      '20261031-1200',
      packPrefix: 'Mi17_PictersKernelPack',
    );
    item['tag_name'] = 'Mi17_Kernel-BakaSU-20261031-1200';
    for (final asset in item['assets'] as List) {
      asset['name'] = (asset['name'] as String).replaceAll(
        'ReSuki-g123-susfs',
        'BakaSU-g123',
      );
    }
    expect(newestManualReleaseCode([item], channel: 'A17'), 610311200);
    expect(newestManualReleaseCode([item], channel: 'A16'), 0);
  });
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
  test('published OOTMODULES pairs still create a release notice', () {
    expect(
      newestManualReleaseCode([
        release('A16', '20261003-0027', packPrefix: 'Mi17_OOTMODULES'),
      ], channel: 'A16'),
      610030027,
    );
  });
  test('SystemPack must match the complete kernel filename', () {
    final mismatched = release('A16', '20261030-1200');
    final assets = mismatched['assets'] as List;
    assets[1]['name'] = (assets[1]['name'] as String).replaceFirst(
      '6.12.23',
      '6.12.69',
    );
    expect(newestManualReleaseCode([mismatched], channel: 'A16'), 0);
  });
  test('a different channel never creates a release notice', () {
    expect(
      newestManualReleaseCode([
        release('A17', '20260930-2330'),
      ], channel: 'A16'),
      0,
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
  test('combined release notifies for each complete Android pair', () {
    final combined = {
      'tag_name': 'Mi17_Kernel-ReSuki-susfs-20261003-0027',
      'assets': [
        ...release('A16', '20261003-0027')['assets'],
        ...release('A17', '20261003-0027')['assets'],
      ],
    };
    expect(newestManualReleaseCode([combined], channel: 'A16'), 610030027);
    expect(newestManualReleaseCode([combined], channel: 'A17'), 610030027);
    expect(newestManualReleaseCode([combined], channel: 'A18'), 0);
  });
  test('combined release requires the pair for the selected channel', () {
    final combined = {
      'tag_name': 'Mi17_Kernel-ReSuki-susfs-20261003-0027',
      'assets': release('A16', '20261003-0027')['assets'],
    };
    expect(newestManualReleaseCode([combined], channel: 'A16'), 610030027);
    expect(newestManualReleaseCode([combined], channel: 'A17'), 0);
  });
  test('previous combined releases with legacy module names do not notify', () {
    expect(
      newestManualReleaseCode([
        {
          'tag_name': 'Mi17_Kernel-ReSuki-susfs-20260727-0620',
          'assets': [
            {'name': 'Mi17_Kernel-OOT-Modules-20260727-0620.zip'},
          ],
        },
      ], channel: 'A16'),
      0,
    );
  });
}
