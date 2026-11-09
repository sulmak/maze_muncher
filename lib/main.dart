import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/scheduler.dart' hide Priority;
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show sqfliteFfiInit, databaseFactoryFfi;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Start-up work must never stop the game from opening. Each step is allowed
  // to fail OR to hang (a step that never finishes would leave a blank screen
  // with no error): after a few seconds we log it and carry on.
  Future<void> safe(String name, Future<void> Function() step) async {
    try {
      await step().timeout(const Duration(seconds: 4));
    } catch (e, st) {
      debugPrint('Start-up step "$name" failed: $e\n$st');
    }
  }

  // The SQLite database only exists on Android, iOS and desktop. On the web
  // we skip it and keep progress in memory.
  if (!kIsWeb) await safe('database', GameDb.open); // 1. open SQLite
  await safe('progress', Progress.load); // 2. restore saved stages
  await safe('food', Food.init); // 3. restore food + offline regen
  runApp(const MazeMuncherApp());
}

/// Set to true while testing to open every stage from the start.
const bool kUnlockAllStages = false;

class MazeMuncherApp extends StatelessWidget {
  const MazeMuncherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Maze Muncher',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const AppLifecycleGate(child: StageSelectPage()),
    );
  }
}

// ---------------------------------------------------------------------------
// Mazes
//   #  wall      .  dot      o  power pellet
//   P  player start          G  enemy start (inside the pen)
// ---------------------------------------------------------------------------
const List<String> mazeA = [
  '###############',
  '#o.....#.....o#',
  '#.##.#.#.#.##.#',
  '#.............#',
  '#.##.#   #.##.#',
  '#....#   #....#',
  '####.#GGG#.####',
  '#....#####....#',
  '#.##.......##.#',
  '#....#.#.#....#',
  '#.##.......##.#',
  '#o.....#.....o#',
  '#.##.#...#.##.#',
  '#......P......#',
  '###############',
];

// ---------------------------------------------------------------------------
// Generated mazes for stages 2-30. Every one is left/right symmetric, fully
// connected, has no dead ends and has wrap-around side tunnels: the blank
// cells at the very edge of a row are the tunnel mouths.
// ---------------------------------------------------------------------------
const List<List<String>> tunnelMazes = [
  // stage 2  (15 rows, 1 tunnel)
  [
    '###############',
    '#o...........o#',
    '#.####.#.####.#',
    '#.....   .....#',
    '####.#   #.####',
    ' ....#   #.... ',
    '####.#GGG#.####',
    '##...#####...##',
    '#..#.......#..#',
    '#.####.#.####.#',
    '#o...........o#',
    '##.##.#.#.##.##',
    '#..##.#.#.##..#',
    '#......P......#',
    '###############',
  ],
  // stage 3  (15 rows, 1 tunnel)
  [
    '###############',
    '#o...........o#',
    '#.##.#.#.#.##.#',
    '#.##..   ..##.#',
    '#....#   #....#',
    '####.#   #.####',
    ' ....#GGG#.... ',
    '####.#####.####',
    '####.......####',
    '#....#.#.#....#',
    '#.##.#.#.#.##.#',
    '#o##...#...##o#',
    '#.##.#.#.#.##.#',
    '#......P......#',
    '###############',
  ],
  // stage 4  (15 rows, 1 tunnel)
  [
    '###############',
    '#o...........o#',
    '#.##.#####.##.#',
    '#.....   .....#',
    '####.#   #.####',
    ' ....#   #.... ',
    '####.#GGG#.####',
    '#....#####....#',
    '#.####...####.#',
    '#.............#',
    '#.#.###.###.#.#',
    '#o#.........#o#',
    '#.##.#####.##.#',
    '#......P......#',
    '###############',
  ],
  // stage 5  (15 rows, 1 tunnel)
  [
    '###############',
    '#o...........o#',
    '#.#.#.###.#.#.#',
    '#.#.#.   .#.#.#',
    '#.#.##   ##.#.#',
    '#.#.##   ##.#.#',
    '#....#GGG#....#',
    '####.#####.####',
    ' ............. ',
    '####.#####.####',
    '#......#......#',
    '#o#.##.#.##.#o#',
    '#.#.##.#.##.#.#',
    '#......P......#',
    '###############',
  ],
  // stage 6  (15 rows, 1 tunnel)
  [
    '###############',
    '#o...........o#',
    '#.#.##.#.##.#.#',
    '#.#...   ...#.#',
    '#.##.#   #.##.#',
    '#....#   #....#',
    '####.#GGG#.####',
    ' ....#####.... ',
    '####.#...#.####',
    '##.....#.....##',
    '##.#.#####.#.##',
    '#o.....#.....o#',
    '#.####.#.####.#',
    '#......P......#',
    '###############',
  ],
  // stage 7  (15 rows, 1 tunnel)
  [
    '###############',
    '#o.#.......#.o#',
    '#....#####....#',
    '####..   ..####',
    ' ....#   #.... ',
    '####.#   #.####',
    '#....#GGG#....#',
    '#.##.#####.##.#',
    '#.............#',
    '##.#.#.#.#.#.##',
    '##.#.#.#.#.#.##',
    '#o.....#.....o#',
    '#.#.##.#.##.#.#',
    '#......P......#',
    '###############',
  ],
  // stage 8  (15 rows, 1 tunnel)
  [
    '###############',
    '#o...........o#',
    '#.###.###.###.#',
    '#.....   .....#',
    '####.#   #.####',
    ' ....#   #.... ',
    '####.#GGG#.####',
    '####.#####.####',
    '##...........##',
    '##.##.#.#.##.##',
    '#.............#',
    '#o#.#.###.#.#o#',
    '#.#.#.###.#.#.#',
    '#......P......#',
    '###############',
  ],
  // stage 9  (17 rows, 1 tunnel)
  [
    '###############',
    '#o....###....o#',
    '#.#.#.....#.#.#',
    '#...#.###.#...#',
    '#.##..   ..##.#',
    '#.##.#   #.##.#',
    '#.##.#   #.##.#',
    '#.##.#GGG#.##.#',
    '#.##.#####.##.#',
    '#o...........o#',
    '#####.#.#.#####',
    ' .....#.#..... ',
    '#####.#.#.#####',
    '##...........##',
    '#..#.##.##.#..#',
    '#......P......#',
    '###############',
  ],
  // stage 10  (17 rows, 2 tunnels)
  [
    '###############',
    '#o.#.......#.o#',
    '#....##.##....#',
    '#####.....#####',
    ' .....   ..... ',
    '####.#   #.####',
    '#....#   #....#',
    '#.##.#GGG#.##.#',
    '#.##.#####.##.#',
    '#....#...#....#',
    '####.#.#.#.####',
    ' ......#...... ',
    '####.#.#.#.####',
    '#o...#...#...o#',
    '#.##.##.##.##.#',
    '#......P......#',
    '###############',
  ],
  // stage 11  (17 rows, 1 tunnel)
  [
    '###############',
    '#o...........o#',
    '#.####.#.####.#',
    '#....#...#....#',
    '##.#..   ..#.##',
    '##.#.#   #.#.##',
    '#..#.#   #.#..#',
    '#....#GGG#....#',
    '####.#####.####',
    ' ............. ',
    '#####.###.#####',
    '#......#......#',
    '#.#.##...##.#.#',
    '#o#....#....#o#',
    '#.#.##.#.##.#.#',
    '#......P......#',
    '###############',
  ],
  // stage 12  (17 rows, 1 tunnel)
  [
    '###############',
    '#o...........o#',
    '#.##.#.#.#.##.#',
    '#.##.#.#.#.##.#',
    '#.##..   ..##.#',
    '#.##.#   #.##.#',
    '#....#   #....#',
    '####.#GGG#.####',
    ' ....#####.... ',
    '####.#...#.####',
    '#.............#',
    '#.#.###.###.#.#',
    '#.#.........#.#',
    '#o###.###.###o#',
    '#.###.###.###.#',
    '#......P......#',
    '###############',
  ],
  // stage 13  (17 rows, 2 tunnels)
  [
    '###############',
    '#o...........o#',
    '#.##.#.#.#.##.#',
    '#.##.#...#.##.#',
    '#.....   .....#',
    '####.#   #.####',
    ' ....#   #.... ',
    '####.#GGG#.####',
    '#....#####....#',
    '#.###.....###.#',
    '#o....#.#....o#',
    '#####.....#####',
    ' ....##.##.... ',
    '####.......####',
    '#..#.##.##.#..#',
    '#......P......#',
    '###############',
  ],
  // stage 14  (17 rows, 1 tunnel)
  [
    '###############',
    '#o...#...#...o#',
    '#.##...#...##.#',
    '#.###.###.###.#',
    '#.##..   ..##.#',
    '#....#   #....#',
    '#.##.#   #.##.#',
    '#.##.#GGG#.##.#',
    '#.##.#####.##.#',
    '#....#...#....#',
    '####.......####',
    ' ....##.##.... ',
    '####.##.##.####',
    '#o...##.##...o#',
    '#.#####.#####.#',
    '#......P......#',
    '###############',
  ],
  // stage 15  (17 rows, 1 tunnel)
  [
    '###############',
    '#o...........o#',
    '#.#####.#####.#',
    '#....#...#....#',
    '#.##..   ..##.#',
    '#.##.#   #.##.#',
    '#....#   #....#',
    '#.##.#GGG#.##.#',
    '#o...#####...o#',
    '####.......####',
    ' ....#####.... ',
    '####.......####',
    '####.#.#.#.####',
    '##...........##',
    '#..####.####..#',
    '#......P......#',
    '###############',
  ],
  // stage 16  (17 rows, 2 tunnels)
  [
    '###############',
    '#o...........o#',
    '#.###.###.###.#',
    '#.###.....###.#',
    '#.....   .....#',
    '####.#   #.####',
    ' ....#   #.... ',
    '####.#GGG#.####',
    '#....#####....#',
    '#.####...####.#',
    '#o.....#.....o#',
    '####.#.#.#.####',
    ' ....#.#.#.... ',
    '####.#.#.#.####',
    '#..#.#.#.#.#..#',
    '#......P......#',
    '###############',
  ],
  // stage 17  (17 rows, 1 tunnel)
  [
    '###############',
    '#o...#...#...o#',
    '#.##...#...##.#',
    '#....#####....#',
    '##.#..   ..#.##',
    '##.#.#   #.#.##',
    '##.#.#   #.#.##',
    '##.#.#GGG#.#.##',
    '#..#.#####.#..#',
    '#.##.......##.#',
    '#o...#.#.#...o#',
    '#####.....#####',
    ' .....###..... ',
    '#####.###.#####',
    '#..##.###.##..#',
    '#......P......#',
    '###############',
  ],
  // stage 18  (19 rows, 1 tunnel)
  [
    '###############',
    '#o...........o#',
    '#.#.##.#.##.#.#',
    '#.#.........#.#',
    '#.##.##.##.##.#',
    '#.##..   ..##.#',
    '#.##.#   #.##.#',
    '#.##.#   #.##.#',
    '#....#GGG#....#',
    '##.#.#####.#.##',
    '#..#...#...#..#',
    '#....#...#....#',
    '####.#.#.#.####',
    ' ....#.#.#.... ',
    '#####.....#####',
    '#o....###....o#',
    '#.###.###.###.#',
    '#......P......#',
    '###############',
  ],
  // stage 19  (19 rows, 2 tunnels)
  [
    '###############',
    '#o..##...##..o#',
    '#.#....#....#.#',
    '#.####.#.####.#',
    '#....#.#.#....#',
    '#.##..   ..##.#',
    '#....#   #....#',
    '####.#   #.####',
    ' ....#GGG#.... ',
    '####.#####.####',
    '#..#.......#..#',
    '#....##.##....#',
    '####.##.##.####',
    ' ....##.##.... ',
    '######...######',
    '#o.....#.....o#',
    '#.###.###.###.#',
    '#......P......#',
    '###############',
  ],
  // stage 20  (19 rows, 1 tunnel)
  [
    '###############',
    '#o.....#.....o#',
    '#.#.##...##.#.#',
    '#.#..#.#.#..#.#',
    '#.##.#...#.##.#',
    '#.##..   ..##.#',
    '#....#   #....#',
    '####.#   #.####',
    ' ....#GGG#.... ',
    '####.#####.####',
    '##...........##',
    '##.####.####.##',
    '#.....#.#.....#',
    '#.###.....###.#',
    '#o....###....o#',
    '##.###...###.##',
    '#..###.#.###..#',
    '#......P......#',
    '###############',
  ],
  // stage 21  (19 rows, 1 tunnel)
  [
    '###############',
    '#o..##...##..o#',
    '#.#....#....#.#',
    '#.####.#.####.#',
    '#....#.#.#....#',
    '#.##..   ..##.#',
    '#....#   #....#',
    '####.#   #.####',
    ' ....#GGG#.... ',
    '####.#####.####',
    '####.#...#.####',
    '#......#......#',
    '#.##.#.#.#.##.#',
    '#.##.#.#.#.##.#',
    '#.##.#.#.#.##.#',
    '#o...........o#',
    '#.###.###.###.#',
    '#......P......#',
    '###############',
  ],
  // stage 22  (19 rows, 2 tunnels)
  [
    '###############',
    '#o.#...#...#.o#',
    '#....#...#....#',
    '####.#.#.#.####',
    ' ....#.#.#.... ',
    '####..   ..####',
    '#....#   #....#',
    '#.##.#   #.##.#',
    '#.##.#GGG#.##.#',
    '#....#####....#',
    '####.......####',
    ' ....##.##.... ',
    '####.##.##.####',
    '###..#...#..###',
    '###.##.#.##.###',
    '#o..##.#.##..o#',
    '#.####.#.####.#',
    '#......P......#',
    '###############',
  ],
  // stage 23  (19 rows, 1 tunnel)
  [
    '###############',
    '#o..#.....#..o#',
    '#.#...#.#...#.#',
    '#.###.#.#.###.#',
    '#.....#.#.....#',
    '####.#   #.####',
    ' ....#   #.... ',
    '####.#   #.####',
    '####.#GGG#.####',
    '#....#####....#',
    '#.##.......##.#',
    '#....#.#.#....#',
    '##.#.#.#.#.#.##',
    '#.............#',
    '#.#####.#####.#',
    '#o..#.....#..o#',
    '#.#.#.#.#.#.#.#',
    '#......P......#',
    '###############',
  ],
  // stage 24  (19 rows, 1 tunnel)
  [
    '###############',
    '#o.....#.....o#',
    '#.#.##.#.##.#.#',
    '#.#.........#.#',
    '#.#.#.###.#.#.#',
    '#.....   .....#',
    '#.##.#   #.##.#',
    '#....#   #....#',
    '#.##.#GGG#.##.#',
    '#o...#####...o#',
    '####.......####',
    ' ....##.##.... ',
    '####.##.##.####',
    '####.##.##.####',
    '##...........##',
    '##.##.###.##.##',
    '#..##.###.##..#',
    '#......P......#',
    '###############',
  ],
  // stage 25  (21 rows, 2 tunnels)
  [
    '###############',
    '#o..##...##..o#',
    '#.#....#....#.#',
    '#.####.#.####.#',
    '#......#......#',
    '#.####.#.####.#',
    '#.....   .....#',
    '####.#   #.####',
    ' ....#   #.... ',
    '####.#GGG#.####',
    '#....#####....#',
    '#.##...#...##.#',
    '#.##.#...#.##.#',
    '#....#.#.#....#',
    '####.#.#.#.####',
    ' ....#.#.#.... ',
    '#####.....#####',
    '#o....#.#....o#',
    '#.#.#.#.#.#.#.#',
    '#......P......#',
    '###############',
  ],
  // stage 26  (21 rows, 1 tunnel)
  [
    '###############',
    '#o..##...##..o#',
    '#.#....#....#.#',
    '#.#.##.#.##.#.#',
    '#...##.#.##...#',
    '#.#.#.....#.#.#',
    '#.#.#.   .#.#.#',
    '#.#.##   ##.#.#',
    '#....#   #....#',
    '#.##.#GGG#.##.#',
    '#.##.#####.##.#',
    '#.............#',
    '####.#.#.#.####',
    ' ....#.#.#.... ',
    '####.......####',
    '#....#####....#',
    '#.###..#..###.#',
    '#o#....#....#o#',
    '#.#.##.#.##.#.#',
    '#......P......#',
    '###############',
  ],
  // stage 27  (21 rows, 1 tunnel)
  [
    '###############',
    '#o.....#.....o#',
    '#.##.#...#.##.#',
    '#.##.#.#.#.##.#',
    '#.#..#.#.#..#.#',
    '#.#.#..#..#.#.#',
    '#...#.   .#...#',
    '#.#.##   ##.#.#',
    '#.#.##   ##.#.#',
    '#....#GGG#....#',
    '####.#####.####',
    ' ............. ',
    '#####.###.#####',
    '###.........###',
    '#...#.###.#...#',
    '#.#...###...#.#',
    '#.####...####.#',
    '#o##...#...##o#',
    '#.##.#####.##.#',
    '#......P......#',
    '###############',
  ],
  // stage 28  (21 rows, 2 tunnels)
  [
    '###############',
    '#o.....#.....o#',
    '#.####...####.#',
    '#......#......#',
    '#####.###.#####',
    ' ......#...... ',
    '####.#   #.####',
    '#....#   #....#',
    '#.##.#   #.##.#',
    '#....#GGG#....#',
    '####.#####.####',
    ' ......#...... ',
    '####.#...#.####',
    '####.#.#.#.####',
    '#....#.#.#....#',
    '#.####.#.####.#',
    '#.##...#...##.#',
    '#o#..#...#..#o#',
    '#.#.###.###.#.#',
    '#......P......#',
    '###############',
  ],
  // stage 29  (21 rows, 1 tunnel)
  [
    '###############',
    '#o...........o#',
    '#.###.###.###.#',
    '#.....###.....#',
    '##.##.....##.##',
    '#....##.##....#',
    '#..#..   ..#..#',
    '####.#   #.####',
    ' ....#   #.... ',
    '####.#GGG#.####',
    '#....#####....#',
    '#.####...####.#',
    '#......#......#',
    '##.###.#.###.##',
    '##.###.#.###.##',
    '#.............#',
    '#.####.#.####.#',
    '#o...........o#',
    '#.##.##.##.##.#',
    '#......P......#',
    '###############',
  ],
  // stage 30  (21 rows, 1 tunnel)
  [
    '###############',
    '#o...........o#',
    '#.#.###.###.#.#',
    '#.#.........#.#',
    '#.###.#.#.###.#',
    '#...#.#.#.#...#',
    '#.#.#.   .#.#.#',
    '#....#   #....#',
    '#.##.#   #.##.#',
    '#.##.#GGG#.##.#',
    '#.##.#####.##.#',
    '#.##.#...#.##.#',
    '#......#......#',
    '####.#.#.#.####',
    ' ....#.#.#.... ',
    '####...#...####',
    '####.#.#.#.####',
    '#o...........o#',
    '#.####.#.####.#',
    '#......P......#',
    '###############',
  ],
];

// ---------------------------------------------------------------------------
// Categories & stages
// ---------------------------------------------------------------------------
enum Category { easy, medium, hard }

extension CategoryX on Category {
  String get label => switch (this) {
        Category.easy => 'EASY',
        Category.medium => 'MEDIUM',
        Category.hard => 'HARD',
      };
  String get tagline => switch (this) {
        Category.easy => 'Slow enemies, long power-ups. Learn the ropes.',
        Category.medium => 'Faster, smarter enemies and tighter mazes.',
        Category.hard => 'Relentless enemies, short power-ups. Good luck.',
      };
  Color get color => switch (this) {
        Category.easy => const Color(0xFF2EE6A6),
        Category.medium => const Color(0xFFFFC857),
        Category.hard => const Color(0xFFFF5A5F),
      };
  IconData get icon => switch (this) {
        Category.easy => Icons.sentiment_satisfied_alt,
        Category.medium => Icons.local_fire_department,
        Category.hard => Icons.whatshot,
      };
}

class StageDef {
  final int number;
  final String name;
  final Category category;
  final List<String> maze;
  final int ghostCount; // 1..3
  final double playerSpeed; // tiles per second
  final double ghostSpeed; // tiles per second
  final double frightenedSecs; // power pellet duration
  final double aggression; // multiplies each enemy's chase probability
  final double releaseScale; // <1 = enemies leave the pen sooner
  final Color wall;
  final Color wallEdge;

  const StageDef({
    required this.number,
    required this.name,
    required this.category,
    required this.maze,
    required this.ghostCount,
    required this.ghostSpeed,
    required this.frightenedSecs,
    required this.aggression,
    required this.wall,
    required this.wallEdge,
    this.playerSpeed = 5.5,
    this.releaseScale = 1.0,
  });

  /// True when the maze has wrap-around side tunnels.
  bool get hasTunnel => maze.any((row) => row[0] != '#');
}

const List<String> _stageNames = [
  'First Bites', 'Warp Gate', 'Garden Loop', 'Sunny Side', 'Pebble Path',
  'Mint Mile', 'Lantern Lane', 'Ribbon Road', 'Cozy Corners', 'Easy Rider',
  'Neon Alley', 'Crossroads', 'Deep Tunnels', 'Echo Chamber', 'Turbo Track',
  'Zigzag Zone', 'Pixel Pass', 'Mirror Maze', 'Hotwire', 'Chain Reaction',
  'The Labyrinth', 'Gauntlet', 'Blackout', 'Razor Wire', 'Iron Gate',
  'Red Alert', 'Dead Zone', 'Meltdown', 'No Mercy', 'Last Stand',
];

/// 30 stages: 1-10 Easy, 11-20 Medium, 21-30 Hard. Difficulty rises smoothly.
List<StageDef> _buildStages() {
  const total = 30;
  return List.generate(total, (i) {
    final t = i / (total - 1);
    final hue = (i * 47.0) % 360;
    return StageDef(
      number: i + 1,
      name: _stageNames[i],
      category: i < 10
          ? Category.easy
          : (i < 20 ? Category.medium : Category.hard),
      maze: i == 0 ? mazeA : tunnelMazes[i - 1],
      ghostCount: i < 4 ? 2 : 3,
      ghostSpeed: 3.3 + 2.0 * t,
      frightenedSecs: 8 - 5 * t,
      aggression: 0.55 + 1.5 * t,
      releaseScale: 1.0 - 0.7 * t,
      wall: HSLColor.fromAHSL(1, hue, 0.60, 0.22).toColor(),
      wallEdge: HSLColor.fromAHSL(1, hue, 0.85, 0.62).toColor(),
    );
  });
}

final List<StageDef> stages = _buildStages();

/// Stage progress. Kept in memory for fast UI reads and mirrored to SQLite
/// (see [GameDb]) so it survives app restarts.
class Progress {
  static final Map<int, int> stars = {}; // stage number -> 1..3 (lives left)
  static final Map<int, int> best = {}; // stage number -> best score
  static int? lastStage; // last stage the player started (for "Continue")

  static Future<void> load() async {
    for (final r in await GameDb.allStages()) {
      final n = r['stage'] as int;
      stars[n] = r['stars'] as int;
      best[n] = r['best_score'] as int;
    }
    lastStage = int.tryParse(await GameDb.getMeta('last_stage') ?? '');
  }

  static void setLast(int stageNumber) {
    lastStage = stageNumber;
    unawaited(GameDb.setMeta('last_stage', '$stageNumber'));
  }

  static bool isUnlocked(StageDef s) =>
      kUnlockAllStages || s.number == 1 || stars.containsKey(s.number - 1);

  static void record(StageDef s, int score, int lives) {
    stars[s.number] = max(stars[s.number] ?? 0, lives);
    best[s.number] = max(best[s.number] ?? 0, score);
    unawaited(GameDb.saveStage(s.number, stars[s.number]!, best[s.number]!));
  }

  static int earnedIn(Category c) => stages
      .where((s) => s.category == c)
      .fold(0, (sum, s) => sum + (stars[s.number] ?? 0));

  static int maxIn(Category c) => stages.where((s) => s.category == c).length * 3;
}

StageDef? nextStageOf(StageDef s) {
  final i = stages.indexWhere((e) => e.number == s.number);
  return (i >= 0 && i + 1 < stages.length) ? stages[i + 1] : null;
}

// ---------------------------------------------------------------------------
// Directions
// ---------------------------------------------------------------------------
enum Dir { up, down, left, right, none }

extension DirX on Dir {
  int get dc => switch (this) {
        Dir.left => -1,
        Dir.right => 1,
        _ => 0,
      };
  int get dr => switch (this) {
        Dir.up => -1,
        Dir.down => 1,
        _ => 0,
      };
  Dir get opposite => switch (this) {
        Dir.up => Dir.down,
        Dir.down => Dir.up,
        Dir.left => Dir.right,
        Dir.right => Dir.left,
        Dir.none => Dir.none,
      };
}

enum GameState { ready, playing, won, lost }

// ---------------------------------------------------------------------------
// Game logic (no Flutter widgets in here)
// ---------------------------------------------------------------------------
class Mover {
  int c, r, nc, nr;
  double t = 0; // progress from (c,r) to (nc,nr)
  bool moving = false;
  Dir dir = Dir.none;

  Mover(this.c, this.r)
      : nc = c,
        nr = r;

  double get x => c + (nc - c) * t;
  double get y => r + (nr - r) * t;

  void reset(int col, int row) {
    c = nc = col;
    r = nr = row;
    t = 0;
    moving = false;
    dir = Dir.none;
  }
}

class Ghost extends Mover {
  final Color color;
  final int homeC, homeR;
  final double chaseProb;
  final double initialDelay;
  double releaseDelay;

  Ghost(super.c, super.r, this.color, this.chaseProb, this.initialDelay)
      : homeC = c,
        homeR = r,
        releaseDelay = initialDelay;

  void sendHome(double delay) {
    reset(homeC, homeR);
    releaseDelay = delay;
  }
}

class Game {
  final StageDef stage;
  final Random rng = Random();

  late final int rows = stage.maze.length;
  late final int cols = stage.maze[0].length;

  /// Rows whose left AND right edge cells are open: walking off one side
  /// brings you back in from the other.
  late final Set<int> tunnelRows = {
    for (var r = 0; r < rows; r++)
      if (stage.maze[r][0] != '#' && stage.maze[r][cols - 1] != '#') r
  };

  late List<List<String>> grid;
  late Mover player;
  late List<Ghost> ghosts;
  int playerStartC = 0, playerStartR = 0;

  int score = 0;
  int lives = 3;
  int dotsLeft = 0;
  int totalDots = 0;
  double frightened = 0;
  double elapsed = 0;
  Dir desired = Dir.none;
  GameState state = GameState.ready;

  Game(this.stage) {
    restart();
  }

  double get progress => totalDots == 0 ? 0 : 1 - dotsLeft / totalDots;

  void restart() {
    grid = [];
    ghosts = [];
    dotsLeft = 0;
    score = 0;
    lives = 3;
    frightened = 0;
    desired = Dir.none;
    state = GameState.ready;

    const colors = [
      Color(0xFFFF5A5F),
      Color(0xFFFF8FD0),
      Color(0xFF3DDCF2),
    ];
    const chase = [0.9, 0.7, 0.5];
    var gi = 0;

    for (var r = 0; r < stage.maze.length; r++) {
      final row = <String>[];
      for (var c = 0; c < stage.maze[r].length; c++) {
        final ch = stage.maze[r][c];
        switch (ch) {
          case '.':
          case 'o':
            dotsLeft++;
            row.add(ch);
          case 'P':
            playerStartC = c;
            playerStartR = r;
            row.add(' ');
          case 'G':
            if (gi < stage.ghostCount) {
              ghosts.add(Ghost(
                c,
                r,
                colors[gi % colors.length],
                (chase[gi % chase.length] * stage.aggression)
                    .clamp(0.0, 0.97)
                    .toDouble(),
                (1.5 + gi * 2.5) * stage.releaseScale,
              ));
            }
            gi++;
            row.add(' ');
          default:
            row.add(ch);
        }
      }
      grid.add(row);
    }
    totalDots = dotsLeft;
    player = Mover(playerStartC, playerStartR);
  }

  /// Column -1 and column [cols] are "virtual" cells just outside the maze.
  /// They are only walkable on tunnel rows and only as a stepping stone to
  /// the other side (see [_advance]).
  bool walkable(int c, int r) {
    if (r < 0 || r >= rows) return false;
    if (c < 0 || c >= cols) {
      return (c == -1 || c == cols) && tunnelRows.contains(r);
    }
    return grid[r][c] != '#';
  }

  bool _outside(int c) => c < 0 || c >= cols;

  /// Maps a (possibly virtual) column to a real maze column.
  int _cell(int c) => c < 0 ? cols - 1 : (c >= cols ? 0 : c);

  // --- input ---------------------------------------------------------------
  void input(Dir d) {
    if (state == GameState.won || state == GameState.lost) return;
    if (state == GameState.ready) state = GameState.playing;
    desired = d;
    // allow instant U-turn while between tiles (not while inside a tunnel)
    if (player.moving &&
        d == player.dir.opposite &&
        !_outside(player.c) &&
        !_outside(player.nc)) {
      final oc = player.c, or = player.r;
      player.c = player.nc;
      player.r = player.nr;
      player.nc = oc;
      player.nr = or;
      player.t = 1 - player.t;
      player.dir = d;
    }
  }

  // --- update --------------------------------------------------------------
  void update(double dt) {
    elapsed += dt;
    if (state != GameState.playing) return;

    if (frightened > 0) frightened = max(0, frightened - dt);

    _advance(player, stage.playerSpeed, dt, _choosePlayer, _onPlayerArrive);

    for (final g in ghosts) {
      if (g.releaseDelay > 0) {
        g.releaseDelay -= dt;
        continue;
      }
      final speed = frightened > 0 ? stage.ghostSpeed * 0.65 : stage.ghostSpeed;
      _advance(g, speed, dt, (m) => _chooseGhost(m as Ghost), (_) {});
    }

    _checkCollisions();
  }

  void _advance(Mover m, double speed, double dt, Dir? Function(Mover) choose,
      void Function(Mover) onArrive) {
    var rem = speed * dt;
    var guard = 0;
    while (rem > 0 && guard++ < 8) {
      if (!m.moving) {
        final d = choose(m);
        if (d == null) break;
        m.dir = d;
        m.nc = m.c + d.dc;
        m.nr = m.r + d.dr;
        m.t = 0;
        m.moving = true;
      }
      final need = 1 - m.t;
      if (rem >= need) {
        rem -= need;
        m.c = m.nc;
        m.r = m.nr;
        m.t = 0;
        m.moving = false;
        // Tunnel: having slid off one edge, re-appear just outside the other
        // edge and keep moving in the same direction.
        if (m.c < 0) {
          m.c = m.nc = cols;
        } else if (m.c >= cols) {
          m.c = m.nc = -1;
        }
        onArrive(m);
        if (state != GameState.playing) return;
      } else {
        m.t += rem;
        rem = 0;
      }
    }
  }

  Dir? _choosePlayer(Mover m) {
    // Inside a tunnel mouth there is no choice: keep going straight.
    if (_outside(m.c)) return m.dir;
    if (desired != Dir.none && walkable(m.c + desired.dc, m.r + desired.dr)) {
      return desired;
    }
    if (m.dir != Dir.none && walkable(m.c + m.dir.dc, m.r + m.dir.dr)) {
      return m.dir;
    }
    return null;
  }

  void _onPlayerArrive(Mover m) {
    if (_outside(m.c)) return; // standing in the virtual tunnel cell
    final cell = grid[m.r][m.c];
    if (cell == '.') {
      score += 10;
      dotsLeft--;
      grid[m.r][m.c] = ' ';
    } else if (cell == 'o') {
      score += 50;
      dotsLeft--;
      grid[m.r][m.c] = ' ';
      frightened = stage.frightenedSecs;
    }
    if (dotsLeft <= 0) state = GameState.won;
  }

  Dir? _chooseGhost(Ghost g) {
    if (_outside(g.c)) return g.dir; // straight through the tunnel
    final options = <Dir>[];
    for (final d in [Dir.up, Dir.left, Dir.down, Dir.right]) {
      if (d == g.dir.opposite) continue;
      if (walkable(g.c + d.dc, g.r + d.dr)) options.add(d);
    }
    if (options.isEmpty) {
      final back = g.dir.opposite;
      if (back != Dir.none && walkable(g.c + back.dc, g.r + back.dr)) {
        return back;
      }
      return null;
    }
    if (frightened > 0 || rng.nextDouble() > g.chaseProb) {
      return options[rng.nextInt(options.length)];
    }
    final dist = _bfsFromPlayer();
    options.sort((a, b) =>
        dist[g.r + a.dr][_cell(g.c + a.dc)]
            .compareTo(dist[g.r + b.dr][_cell(g.c + b.dc)]));
    return options.first;
  }

  /// Walking distance from the player to every cell, tunnels included.
  List<List<int>> _bfsFromPlayer() {
    final dist = List.generate(rows, (_) => List.filled(cols, 9999));
    final pc = player.x.round().clamp(0, cols - 1).toInt();
    final pr = player.y.round().clamp(0, rows - 1).toInt();
    final q = Queue<(int, int)>()..add((pc, pr));
    dist[pr][pc] = 0;
    while (q.isNotEmpty) {
      final (c, r) = q.removeFirst();
      for (final d in [Dir.up, Dir.down, Dir.left, Dir.right]) {
        final nc = c + d.dc, nr = r + d.dr;
        if (!walkable(nc, nr)) continue;
        final cc = _cell(nc);
        if (dist[nr][cc] == 9999) {
          dist[nr][cc] = dist[r][c] + 1;
          q.add((cc, nr));
        }
      }
    }
    return dist;
  }

  void _checkCollisions() {
    for (final g in ghosts) {
      if (g.releaseDelay > 0) continue;
      // Positions loop with period cols + 1 along tunnel rows.
      var dx = (g.x - player.x).abs();
      final period = cols + 1.0;
      if (dx > period / 2) dx = period - dx;
      final dy = g.y - player.y;
      if (dx * dx + dy * dy < 0.45 * 0.45 * 2) {
        if (frightened > 0) {
          score += 200;
          g.sendHome(2.0);
        } else {
          lives--;
          if (lives <= 0) {
            state = GameState.lost;
          } else {
            _resetPositions();
          }
          return;
        }
      }
    }
  }

  void _resetPositions() {
    player.reset(playerStartC, playerStartR);
    desired = Dir.none;
    frightened = 0;
    for (final g in ghosts) {
      g.sendHome(g.initialDelay);
    }
    state = GameState.ready;
  }
}

// ---------------------------------------------------------------------------
// Stage select screen
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Database (SQLite via sqflite)
//   stage_progress : one row per cleared stage
//   meta           : small key/value store (food count, regen anchor, last stage)
// ---------------------------------------------------------------------------
bool get _isDesktop =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Push notifications are only wired up for Android and iOS.
bool get _notificationsSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

class GameDb {
  static Database? _db;

  // Used only if the database cannot be opened, so the game still runs.
  static final Map<int, Map<String, Object?>> _memStages = {};
  static final Map<String, String> _memMeta = {};

  static Future<void> open() async {
    try {
      if (_isDesktop) {
        sqfliteFfiInit(); // Windows / Linux / macOS use the FFI SQLite
        databaseFactory = databaseFactoryFfi;
      }
      _db = await openDatabase(
        '${await getDatabasesPath()}/maze_muncher.db',
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE stage_progress(
              stage      INTEGER PRIMARY KEY,
              stars      INTEGER NOT NULL,
              best_score INTEGER NOT NULL,
              updated_at INTEGER NOT NULL
            )''');
          await db.execute(
              'CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        },
      );
    } catch (e) {
      _db = null;
      debugPrint('Database unavailable, progress will not be saved: $e');
    }
  }

  static Future<List<Map<String, Object?>>> allStages() async {
    final db = _db;
    if (db == null) return _memStages.values.toList();
    return db.query('stage_progress');
  }

  static Future<void> saveStage(int stage, int stars, int bestScore) async {
    final row = <String, Object?>{
      'stage': stage,
      'stars': stars,
      'best_score': bestScore,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
    final db = _db;
    if (db == null) {
      _memStages[stage] = row;
      return;
    }
    await db.insert('stage_progress', row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<String?> getMeta(String key) async {
    final db = _db;
    if (db == null) return _memMeta[key];
    final rows =
        await db.query('meta', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  static Future<void> setMeta(String key, String value) async {
    final db = _db;
    if (db == null) {
      _memMeta[key] = value;
      return;
    }
    await db.insert('meta', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

// ---------------------------------------------------------------------------
// Food: a regenerating resource. Starting a stage attempt costs 1 food.
// One food is generated every [interval], up to [max]. Regeneration keeps
// running while the app is closed: we store a timestamp ("anchor") and work
// out how much was earned when the app starts or resumes. A local push
// notification is scheduled for the moment food becomes available again.
// ---------------------------------------------------------------------------
class Food {
  static const int max = 5;
  static const Duration interval = Duration(minutes: 10); // <- tune this

  static final ValueNotifier<int> count = ValueNotifier<int>(max);
  static DateTime _anchor = DateTime.now(); // start of the current regen cycle

  static final FlutterLocalNotificationsPlugin _notif =
      FlutterLocalNotificationsPlugin();
  static const int _notifId = 1;

  static Future<void> init() async {
    if (_notificationsSupported) {
      try {
        tzdata.initializeTimeZones();
        await _notif.initialize(const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ));
        await _notif
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      } catch (e) {
        debugPrint('Notifications unavailable: $e');
      }
    }

    final savedCount = await GameDb.getMeta('food');
    final savedAnchor = await GameDb.getMeta('food_anchor');
    if (savedCount == null || savedAnchor == null) {
      count.value = max; // first launch: start full
      _anchor = DateTime.now();
    } else {
      count.value = int.parse(savedCount).clamp(0, max).toInt();
      _anchor = DateTime.fromMillisecondsSinceEpoch(int.parse(savedAnchor));
    }
    await refresh();
  }

  /// Time until the next food is generated, or null when full.
  static Duration? get untilNext {
    if (count.value >= max) return null;
    final left = _anchor.add(interval).difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Time until food is completely full, or null when already full.
  static Duration? get untilFull {
    if (count.value >= max) return null;
    return _anchor
        .add(interval * (max - count.value))
        .difference(DateTime.now());
  }

  /// Applies any regeneration earned since the anchor. Returns true if the
  /// food count changed.
  static bool _applyRegen() {
    final now = DateTime.now();
    if (count.value >= max) {
      _anchor = now;
      return false;
    }
    if (now.isBefore(_anchor)) _anchor = now; // clock was set backwards
    final gained = now.difference(_anchor).inSeconds ~/ interval.inSeconds;
    if (gained <= 0) return false;
    count.value = (count.value + gained).clamp(0, max).toInt();
    _anchor = count.value >= max ? now : _anchor.add(interval * gained);
    return true;
  }

  /// Call on start-up, on app resume and after any change.
  static Future<void> refresh() async {
    _applyRegen();
    await _persist();
    await _reschedule();
  }

  /// Cheap once-per-second check used by the UI countdown.
  static void tick() {
    final left = untilNext;
    if (left != null && left == Duration.zero) unawaited(refresh());
  }

  /// Pays 1 food. Returns false (and changes nothing) if there is none.
  static Future<bool> spend() async {
    _applyRegen();
    if (count.value <= 0) return false;
    if (count.value >= max) _anchor = DateTime.now(); // timer starts now
    count.value = count.value - 1;
    await _persist();
    await _reschedule();
    return true;
  }

  static Future<void> _persist() async {
    await GameDb.setMeta('food', '${count.value}');
    await GameDb.setMeta('food_anchor', '${_anchor.millisecondsSinceEpoch}');
  }

  /// One pending notification: "food is ready" when empty, otherwise
  /// "food is full".
  static Future<void> _reschedule() async {
    if (!_notificationsSupported) return;
    try {
      await _rescheduleInner();
    } catch (e) {
      debugPrint('Could not schedule notification: $e');
    }
  }

  static Future<void> _rescheduleInner() async {
    await _notif.cancel(_notifId);
    if (count.value >= max) return;
    final empty = count.value == 0;
    final when = empty
        ? _anchor.add(interval)
        : _anchor.add(interval * (max - count.value));
    if (!when.isAfter(DateTime.now())) return;
    await _notif.zonedSchedule(
      _notifId,
      'Maze Muncher',
      empty ? 'Fresh food is ready - come munch!' : 'Your food is full again!',
      // An absolute instant, so UTC is fine (no local-timezone package needed).
      tz.TZDateTime.from(when, tz.UTC),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'food_refill',
          'Food refill',
          channelDescription: 'Tells you when your food has regenerated',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }
}

String formatDuration(Duration d) {
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

void showNoFood(BuildContext context) {
  final left = Food.untilNext;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(left == null
          ? 'Out of food!'
          : 'Out of food! Next one in ${formatDuration(left)}.'),
      duration: const Duration(seconds: 2),
    ));
}

/// Resume system: when the app comes back to the foreground, catch up on food
/// generated while away; when it goes to the background, make sure the refill
/// notification is scheduled.
class AppLifecycleGate extends StatefulWidget {
  final Widget child;
  const AppLifecycleGate({super.key, required this.child});

  @override
  State<AppLifecycleGate> createState() => _AppLifecycleGateState();
}

class _AppLifecycleGateState extends State<AppLifecycleGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused) {
      unawaited(Food.refresh()); // catch up (resume) / re-schedule (pause)
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Food icons + countdown to the next refill.
class FoodBar extends StatefulWidget {
  const FoodBar({super.key});

  @override
  State<FoodBar> createState() => _FoodBarState();
}

class _FoodBarState extends State<FoodBar> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      Food.tick();
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: Food.count,
      builder: (_, n, _) {
        final left = Food.untilNext;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < Food.max; i++)
                Icon(Icons.fastfood_rounded,
                    size: 18,
                    color: i < n ? const Color(0xFFFFC857) : Colors.white24),
            ]),
            Text(left == null ? 'Full' : 'Next ${formatDuration(left)}',
                style: const TextStyle(fontSize: 11, color: Colors.white54)),
          ],
        );
      },
    );
  }
}

const String kAuthorName = 'Md. Atikur Rahman Mridha';

/// "Powered by" credit shown at the bottom of the stage screen.
/// (Author: $kAuthorName - intentionally not shown in the UI.)
class _CreditsFooter extends StatelessWidget {
  const _CreditsFooter();

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(fontSize: 11, color: Colors.white54);
    return const Padding(
      padding: EdgeInsets.only(bottom: 10),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Powered by $kAuthorName', style: style),
          ],
        ),
      ),
    );
  }
}

class StageSelectPage extends StatefulWidget {
  const StageSelectPage({super.key});

  @override
  State<StageSelectPage> createState() => _StageSelectPageState();
}

class _StageSelectPageState extends State<StageSelectPage> {
  Category _cat = Category.easy;

  Future<void> _open(StageDef s) async {
    if (!Progress.isUnlocked(s)) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text('Clear stage ${s.number - 1} to unlock this one.'),
          duration: const Duration(seconds: 2),
        ));
      return;
    }
    if (!await Food.spend()) {
      if (mounted) showNoFood(context);
      return;
    }
    Progress.setLast(s.number);
    if (!mounted) return;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => GamePage(stage: s)))
        .then((_) => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    final list = stages.where((s) => s.category == _cat).toList();
    final lastStage =
        stages.where((s) => s.number == Progress.lastStage).firstOrNull;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B1A),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: FittedBox(
                      alignment: Alignment.centerLeft,
                      fit: BoxFit.scaleDown,
                      child: Text('MAZE MUNCHER',
                          style: TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                              color: Color(0xFF2EE6A6))),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const FoodBar(),
                ],
              ),
              const SizedBox(height: 4),
              const Text('Choose a category and a stage',
                  style: TextStyle(color: Colors.white60)),
              if (lastStage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton.icon(
                    onPressed: () => _open(lastStage),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: Text('Continue - Stage ${lastStage.number}'),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  for (final c in Category.values)
                    Expanded(child: _categoryTab(c)),
                ],
              ),
              const SizedBox(height: 12),
              Text(_cat.tagline, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 220,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.95,
                  ),
                  itemCount: list.length,
                  itemBuilder: (_, i) => _stageCard(list[i]),
                ),
              ),
              const _CreditsFooter(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _categoryTab(Category c) {
    final selected = c == _cat;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _cat = c),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? c.color.withValues(alpha: 0.18) : Colors.white10,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: selected ? c.color : Colors.transparent, width: 2),
          ),
          child: Column(
            children: [
              Icon(c.icon, color: c.color, size: 22),
              const SizedBox(height: 2),
              Text(c.label,
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: selected ? c.color : Colors.white70)),
              Text('${Progress.earnedIn(c)}/${Progress.maxIn(c)} ★',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stageCard(StageDef s) {
    final unlocked = Progress.isUnlocked(s);
    final got = Progress.stars[s.number] ?? 0;
    final best = Progress.best[s.number];
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _open(s),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: unlocked ? s.category.color.withValues(alpha: 0.7) : Colors.white12,
              width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('STAGE ${s.number}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                        color: s.category.color)),
                const Spacer(),
                if (s.hasTunnel)
                  Tooltip(
                    message: 'Has side tunnels',
                    child: Icon(Icons.swap_horiz,
                        size: 18,
                        color: unlocked ? s.category.color : Colors.white24),
                  ),
                if (!unlocked)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(Icons.lock, size: 16, color: Colors.white38),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: Opacity(
                opacity: unlocked ? 1 : 0.35,
                child: SizedBox.expand(
                  child: CustomPaint(
                    painter: MazeThumbPainter(s.maze, s.wall, s.wallEdge),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(s.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: unlocked ? Colors.white : Colors.white38)),
            const SizedBox(height: 2),
            Row(
              children: [
                for (var i = 0; i < 3; i++)
                  Icon(i < got ? Icons.star : Icons.star_border,
                      size: 16,
                      color: i < got ? const Color(0xFFFFC857) : Colors.white24),
                const Spacer(),
                if (best != null)
                  Text('$best',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.white60)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class MazeThumbPainter extends CustomPainter {
  final List<String> maze;
  final Color fill, edge;
  MazeThumbPainter(this.maze, this.fill, this.edge);

  @override
  void paint(Canvas canvas, Size size) {
    final rows = maze.length, cols = maze[0].length;
    final tile = min(size.width / cols, size.height / rows);
    final ox = (size.width - tile * cols) / 2;
    final oy = (size.height - tile * rows) / 2;
    final fillP = Paint()..color = fill;
    final edgeP = Paint()
      ..color = edge.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(0.5, tile * 0.1);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        if (maze[r][c] == '#') {
          final rr = RRect.fromRectAndRadius(
            Rect.fromLTWH(ox + c * tile + 0.5, oy + r * tile + 0.5,
                tile - 1, tile - 1),
            Radius.circular(tile * 0.25),
          );
          canvas.drawRRect(rr, fillP);
          canvas.drawRRect(rr, edgeP);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant MazeThumbPainter old) => false;
}

// ---------------------------------------------------------------------------
// Game screen
// ---------------------------------------------------------------------------
class GamePage extends StatefulWidget {
  final StageDef stage;
  const GamePage({super.key, required this.stage});

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late StageDef stage;
  late Game game;
  late final Ticker _ticker;
  Duration _last = Duration.zero;
  final FocusNode _focus = FocusNode();
  bool _recorded = false;
  bool _spending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    stage = widget.stage;
    game = Game(stage);
    _ticker = createTicker((d) {
      final dt = ((d - _last).inMicroseconds / 1e6).clamp(0.0, 0.05).toDouble();
      _last = d;
      game.update(dt);
      if (game.state == GameState.won && !_recorded) {
        _recorded = true;
        Progress.record(stage, game.score, game.lives);
      }
      setState(() {});
    })
      ..start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Pause the game when the app leaves the foreground, resume when it returns.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_ticker.isActive) {
        _last = Duration.zero;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  void _load(StageDef s) {
    stage = s;
    game = Game(s);
    _recorded = false;
  }

  /// Every new attempt costs 1 food.
  Future<bool> _pay() async {
    if (_spending) return false;
    _spending = true;
    final ok = await Food.spend();
    _spending = false;
    if (!ok && mounted) showNoFood(context);
    return ok && mounted;
  }

  Future<void> _retry() async {
    if (await _pay()) _load(stage);
  }

  Future<void> _next() async {
    final n = nextStageOf(stage);
    if (n == null) return;
    if (await _pay()) {
      Progress.setLast(n.number);
      _load(n);
    }
  }

  void _primaryAction() {
    if (game.state == GameState.won) {
      if (nextStageOf(stage) != null) {
        _next();
      } else {
        Navigator.of(context).maybePop();
      }
    } else if (game.state == GameState.lost) {
      _retry();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.keyW) {
      game.input(Dir.up);
    } else if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.keyS) {
      game.input(Dir.down);
    } else if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.keyA) {
      game.input(Dir.left);
    } else if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.keyD) {
      game.input(Dir.right);
    } else if (k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.enter) {
      _primaryAction();
    } else if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B1A),
      body: SafeArea(
        child: Focus(
          autofocus: true,
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: Column(
            children: [
              _hud(),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) {
                    final dx = d.delta.dx, dy = d.delta.dy;
                    if (dx.abs() > dy.abs()) {
                      if (dx.abs() > 2) game.input(dx > 0 ? Dir.right : Dir.left);
                    } else if (dy.abs() > 2) {
                      game.input(dy > 0 ? Dir.down : Dir.up);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(painter: GamePainter(game)),
                        ),
                        if (game.state != GameState.playing) _overlay(),
                      ],
                    ),
                  ),
                ),
              ),
              _dpad(),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hud() {
    final cat = stage.category;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('STAGE ${stage.number} · ${stage.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                      decoration: BoxDecoration(
                        color: cat.color.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(cat.label,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: cat.color)),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('SCORE ${game.score}',
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1)),
                  const SizedBox(height: 4),
                  Row(
                    children: List.generate(
                      game.lives,
                      (_) => const Padding(
                        padding: EdgeInsets.only(left: 5),
                        child: Icon(Icons.circle,
                            size: 14, color: Color(0xFF2EE6A6)),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: game.progress,
                minHeight: 5,
                color: cat.color,
                backgroundColor: Colors.white12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _overlay() {
    final cat = stage.category;
    final next = nextStageOf(stage);
    late final String title;
    late final String sub;
    switch (game.state) {
      case GameState.ready:
        title = 'READY';
        sub = 'Swipe, use arrow keys / WASD, or the D-pad to start'
            '${stage.hasTunnel ? '\nSide tunnels teleport you to the other side' : ''}';
      case GameState.won:
        title = 'STAGE CLEAR!';
        sub = 'Score ${game.score}  ·  ${'★' * game.lives}${'☆' * (3 - game.lives)}';
      case GameState.lost:
        title = 'GAME OVER';
        sub = 'Score ${game.score}';
      case GameState.playing:
        title = '';
        sub = '';
    }

    final buttons = <Widget>[];
    if (game.state == GameState.won) {
      if (next != null) {
        buttons.add(FilledButton.icon(
          onPressed: _next,
          icon: const Icon(Icons.skip_next),
          label: Text('Next: ${next.name}'),
        ));
      } else {
        buttons.add(const Text('All stages cleared! 🎉',
            style: TextStyle(fontWeight: FontWeight.bold)));
      }
      buttons.add(TextButton(onPressed: _retry, child: const Text('Replay')));
      buttons.add(TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Stage menu')));
    } else if (game.state == GameState.lost) {
      buttons.add(FilledButton.icon(
        onPressed: _retry,
        icon: const Icon(Icons.refresh),
        label: const Text('Try again'),
      ));
      buttons.add(TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Stage menu')));
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cat.color.withValues(alpha: 0.6)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${cat.label} · STAGE ${stage.number}',
              style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 1.5,
                  fontWeight: FontWeight.bold,
                  color: cat.color)),
          Text(stage.name,
              style: const TextStyle(fontSize: 14, color: Colors.white70)),
          const SizedBox(height: 8),
          Text(title,
              style: TextStyle(
                  fontSize: 32, fontWeight: FontWeight.w900, color: cat.color)),
          const SizedBox(height: 6),
          Text(sub, textAlign: TextAlign.center),
          if (buttons.isNotEmpty) const SizedBox(height: 10),
          ...buttons,
        ],
      ),
    );
  }

  Widget _dpad() {
    Widget btn(IconData icon, Dir d) => Padding(
          padding: const EdgeInsets.all(2),
          child: IconButton.filledTonal(
            onPressed: () => game.input(d),
            icon: Icon(icon, size: 30),
          ),
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.keyboard_arrow_up, Dir.up),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            btn(Icons.keyboard_arrow_left, Dir.left),
            const SizedBox(width: 52),
            btn(Icons.keyboard_arrow_right, Dir.right),
          ],
        ),
        btn(Icons.keyboard_arrow_down, Dir.down),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Painter
// ---------------------------------------------------------------------------
class GamePainter extends CustomPainter {
  final Game g;
  GamePainter(this.g);

  @override
  void paint(Canvas canvas, Size size) {
    final tile = min(size.width / g.cols, size.height / g.rows);
    final ox = (size.width - tile * g.cols) / 2;
    final oy = (size.height - tile * g.rows) / 2;
    canvas.translate(ox, oy);

    _drawMaze(canvas, tile);
    _drawTunnelArrows(canvas, tile);

    // Clip characters to the maze so they vanish at the edge while using a
    // tunnel and slide back in from the opposite side.
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, tile * g.cols, tile * g.rows));
    _drawPlayer(canvas, tile);
    for (final gh in g.ghosts) {
      _drawGhost(canvas, tile, gh);
    }
    canvas.restore();
  }

  void _drawTunnelArrows(Canvas canvas, double tile) {
    final alpha = 0.35 + 0.25 * sin(g.elapsed * 5);
    final paint = Paint()..color = g.stage.wallEdge.withValues(alpha: alpha);
    for (final r in g.tunnelRows) {
      final cy = (r + 0.5) * tile;
      final h = tile * 0.2;
      // left mouth, arrow pointing out to the left
      canvas.drawPath(
        Path()
          ..moveTo(tile * 0.12, cy)
          ..lineTo(tile * 0.4, cy - h)
          ..lineTo(tile * 0.4, cy + h)
          ..close(),
        paint,
      );
      // right mouth, arrow pointing out to the right
      final rx = tile * g.cols;
      canvas.drawPath(
        Path()
          ..moveTo(rx - tile * 0.12, cy)
          ..lineTo(rx - tile * 0.4, cy - h)
          ..lineTo(rx - tile * 0.4, cy + h)
          ..close(),
        paint,
      );
    }
  }

  void _drawMaze(Canvas canvas, double tile) {
    final wallFill = Paint()..color = g.stage.wall;
    final wallEdge = Paint()
      ..color = g.stage.wallEdge
      ..style = PaintingStyle.stroke
      ..strokeWidth = tile * 0.08;
    final dot = Paint()..color = const Color(0xFFFFE9B0);
    final pellet = Paint()..color = const Color(0xFFFFC857);

    for (var r = 0; r < g.rows; r++) {
      for (var c = 0; c < g.cols; c++) {
        final cell = g.grid[r][c];
        if (cell == '#') {
          final rr = RRect.fromRectAndRadius(
            Rect.fromLTWH(c * tile + tile * 0.06, r * tile + tile * 0.06,
                tile * 0.88, tile * 0.88),
            Radius.circular(tile * 0.25),
          );
          canvas.drawRRect(rr, wallFill);
          canvas.drawRRect(rr, wallEdge);
        } else if (cell == '.') {
          canvas.drawCircle(
              Offset((c + 0.5) * tile, (r + 0.5) * tile), tile * 0.08, dot);
        } else if (cell == 'o') {
          final pulse = 0.2 + 0.05 * sin(g.elapsed * 6);
          canvas.drawCircle(
              Offset((c + 0.5) * tile, (r + 0.5) * tile), tile * pulse, pellet);
        }
      }
    }
  }

  void _drawPlayer(Canvas canvas, double tile) {
    final p = g.player;
    final center = Offset((p.x + 0.5) * tile, (p.y + 0.5) * tile);
    final rad = tile * 0.42;
    final facing = switch (p.dir) {
      Dir.right => 0.0,
      Dir.down => pi / 2,
      Dir.left => pi,
      Dir.up => 3 * pi / 2,
      Dir.none => 0.0,
    };
    final mouth =
        p.moving ? 0.1 + 0.55 * (0.5 + 0.5 * sin(g.elapsed * 18)) : 0.25;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: rad),
      facing + mouth,
      2 * pi - 2 * mouth,
      true,
      Paint()..color = const Color(0xFF2EE6A6),
    );

    // eye
    final eyeAngle = facing - pi / 2;
    final eye = center +
        Offset(cos(eyeAngle), sin(eyeAngle)) * rad * 0.45 +
        Offset(cos(facing), sin(facing)) * rad * 0.1;
    canvas.drawCircle(eye, tile * 0.07, Paint()..color = const Color(0xFF0B0B1A));
  }

  void _drawGhost(Canvas canvas, double tile, Ghost gh) {
    final center = Offset((gh.x + 0.5) * tile, (gh.y + 0.5) * tile);
    final scared = g.frightened > 0;
    final flicker = scared && g.frightened < 2 && sin(g.elapsed * 14) > 0;
    final body = scared
        ? (flicker ? const Color(0xFFEFEFEF) : const Color(0xFF3B4CCA))
        : gh.color;

    // body: a rounded "bot" with an antenna
    final rect =
        Rect.fromCenter(center: center, width: tile * 0.8, height: tile * 0.72);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(tile * 0.22)),
      Paint()..color = body,
    );
    final stroke = Paint()
      ..color = body
      ..strokeWidth = tile * 0.06
      ..strokeCap = StrokeCap.round;
    final top = Offset(center.dx, rect.top);
    canvas.drawLine(top, top + Offset(0, -tile * 0.14), stroke);
    canvas.drawCircle(
        top + Offset(0, -tile * 0.16), tile * 0.06, Paint()..color = body);

    // eyes
    final eyeY = center.dy - tile * 0.05;
    final look = Offset(gh.dir.dc * tile * 0.03, gh.dir.dr * tile * 0.03);
    for (final dx in [-tile * 0.17, tile * 0.17]) {
      final e = Offset(center.dx + dx, eyeY);
      if (scared) {
        canvas.drawCircle(e, tile * 0.05, Paint()..color = Colors.white);
      } else {
        canvas.drawCircle(e, tile * 0.1, Paint()..color = Colors.white);
        canvas.drawCircle(
            e + look, tile * 0.05, Paint()..color = const Color(0xFF0B0B1A));
      }
    }
  }

  @override
  bool shouldRepaint(covariant GamePainter oldDelegate) => true;
}
