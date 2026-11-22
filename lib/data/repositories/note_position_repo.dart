// 规格: 02 §1.1 §8.1 / 04 note_position（静态 22 行种子）。
library;

import 'package:sqflite_common/sqlite_api.dart';

import '../../domain/models/note_position.dart';

NotePosition _fromRow(Map<String, Object?> row) => NotePosition(
      diatonicIndex: row['diatonic_index'] as int,
      displayName: row['display_name'] as String,
      pitchClass: row['pitch_class'] as String,
      octave: row['octave'] as int,
      midi: row['midi'] as int,
      inTreble: (row['in_treble'] as int) == 1,
      inBass: (row['in_bass'] as int) == 1,
      ledgerTreble: (row['ledger_treble'] as int) == 1,
      ledgerBass: (row['ledger_bass'] as int) == 1,
    );

class NotePositionRepo {
  final Database _db;
  NotePositionRepo(this._db);

  /// 全部 22 音位，按 diatonic_index 升序（C3=-7 … C6=14）。
  Future<List<NotePosition>> all() async {
    final rows =
        await _db.query('note_position', orderBy: 'diatonic_index ASC');
    return rows.map(_fromRow).toList();
  }

  Future<NotePosition?> byIndex(int diatonicIndex) async {
    final rows = await _db.query('note_position',
        where: 'diatonic_index = ?', whereArgs: [diatonicIndex]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }
}