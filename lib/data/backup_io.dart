// 规格: 06 §2 S6 / 02 §8.7 —— 备份文件的系统分享/选择（平台 I/O 隔离）。
//
// 页面只依赖 BackupIo 抽象，便于 widget 测试注入假实现；share_plus /
// file_picker / path_provider 仅出现在默认实现 PlatformBackupIo 中。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

abstract class BackupIo {
  /// 把 JSON 文本写成临时文件并唤起系统分享面板。
  Future<void> shareJson(String fileName, String json);

  /// 选择并读取 JSON 文本；用户取消返回 null。
  Future<String?> pickJson();
}

/// 生产实现：path_provider 临时目录 + share_plus；导入用 file_picker。
class PlatformBackupIo implements BackupIo {
  const PlatformBackupIo();

  @override
  Future<void> shareJson(String fileName, String json) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(json, flush: true);
    await SharePlus.instance.share(ShareParams(
      files: [XFile(file.path)],
      subject: '识谱训练备份',
    ));
  }

  @override
  Future<String?> pickJson() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (files.isEmpty) return null;
    return utf8.decode(await files.first.readAsBytes());
  }
}
