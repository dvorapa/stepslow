import 'package:flutter/material.dart';
import 'dart:collection' show SplayTreeMap;
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:math';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:flutter_beep/flutter_beep.dart' show FlutterBeep;
import 'package:wakelock/wakelock.dart' show Wakelock;
import 'package:collection/collection.dart' show IterableExtension;
import 'package:volume_regulator/volume_regulator.dart' show VolumeRegulator;
import 'package:easy_dialogs/easy_dialogs.dart' show SingleChoiceDialog;
import 'package:typicons_flutter/typicons_flutter.dart' show Typicons;
import 'package:shared_preferences/shared_preferences.dart'
    show SharedPreferences;
import 'package:yaml/yaml.dart';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart' show FFmpegKit;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'pubspec.dart' show Pubspec;
import 'package:about/about.dart' show showMarkdownPage;
import 'package:url_launcher/url_launcher.dart' show launchUrl;
import 'package:flutter/cupertino.dart' show CupertinoIcons;

/// Theme main color
final Color interactiveColor = Colors.orange[300]!; // #FFB74D #FFA726

/// Light theme color
const Color backgroundColor = Colors.white;

/// Special and YouTube components color
const Color redColor = Colors.red; // #E4273A

/// Text main color
final Color unfocusedColor = Colors.grey[400]!;

/// Dark theme color
const Color blackColor = Colors.black;

/// Duration initializer
Duration _emptyDuration = Duration.zero;

/// Default duration for empty queue
Duration _defaultDuration = const Duration(seconds: 5);

/// Default duration for animations
Duration _animationDuration = const Duration(milliseconds: 300);

/// Default duration for animations
const Curve _animationCurve = Curves.ease;

/// Available sources
final List<Source> _sources = [Source('/storage/emulated/0', 0)];

/// List of completer bad states
// -1 for complete, -2 for error, natural for count
final List<int> _bad = [0, -2];

/// Prints long messages, e.g. maps
void printLong(Object text) {
  text = text.toString();
  final Pattern pattern = RegExp('.{1,1023}');
  pattern
      .allMatches(text as String)
      .map((Match match) => match.group(0))
      .forEach(print);
}

/// Changes app data folders
bool _debug = false;

/// Pads seconds
String zero(int n) {
  if (n >= 10) return '$n';
  return '0$n';
}

/// Calculates height factor for wave
double _heightFactor(double height, int avolume, double value) =>
    height *
    (.81 - .56 * (1.0 - avolume / 100.0) - .25 * (1.0 - value / 100.0));

/// Filesystem entity representing a song or a folder.
class Entry implements Comparable<Entry> {
  /// Entry constructor
  Entry(this.path, this.type);

  /// Entry full path (contains filename)
  String path;

  /// Song or folder switch
  String type = 'song';

  /// Songs in folder count
  int songs = 0;

  @override
  int compareTo(Entry other) =>
      path.toLowerCase().compareTo(other.path.toLowerCase());

  @override
  String toString() => 'Entry( $path )';

  @override
  bool operator ==(Object other) => other is Entry && other.path == path;

  @override
  int get hashCode => path.hashCode;

  /// Entry name
  String get name {
    if (_sources.any((Source asource) => asource.root == path)) return '';

    return path.split('/').lastWhere((String e) => e != '');
  }
}

/// Filesystem entity representing a source of songs.
class Source implements Pattern {
  /// Source constructor
  Source(this.root, this.id);

  /// Source root path
  String root;

  /// Order factor
  /// -1 for YouTube, 0 for Device, natural for others
  int id = 0;

  /// Stack of filesystem entities inside Source
  SplayTreeMap<Entry, SplayTreeMap> browse = SplayTreeMap();

  /// Source folder stack completer
  int browseFoldersComplete = 0;

  /// Source path to store covers
  String? coversPath;

  @override
  bool operator ==(Object other) => other is Source && other.root == root;

  @override
  int get hashCode => root.hashCode;

  @override
  Iterable<Match> allMatches(String string, [int start = 0]) =>
      root.allMatches(string, start);

  @override
  Match? matchAsPrefix(String string, [int start = 0]) =>
      root.matchAsPrefix(string, start);

  @override
  String toString() => 'Source( $root )';

  /// YouTube, internal or external device
  String get type {
    switch (id) {
      case 0:
        return 'Device';
      case -1:
        return 'YouTube';
      default:
        return 'SD card';
    }
  }

  /// Source name
  String get name {
    if (id <= 0) return type;
    return '$type $id';
  }
}

/// Lists subfolders of [root] path string
Stream<String> getFolders(String root) async* {
  await for (final FileSystemEntity subDir
      in Directory(root).list(recursive: true)) {
    try {
      final String subDirPath = subDir.path;
      if (subDir is Directory &&
          !subDirPath
              .split('/')
              .lastWhere((String e) => e != '')
              .startsWith('.')) {
        yield subDirPath;
      }
    } on FileSystemException {
      continue;
    }
  }
}

/// Finds SD card(s) if any and creates [Source] from them
Stream<Source> checkoutSdCards() async* {
  int n = 1;
  await for (final FileSystemEntity subDir in Directory('/storage').list()) {
    try {
      if (subDir is Directory && !await subDir.list().isEmpty) {
        yield Source(subDir.path, n);
        n++;
      }
    } on FileSystemException {
      continue;
    }
  }
}

/// Starts app
void main() => runApp(const Stepslow());

/// Stateless app entrypoint and theme initializer.
class Stepslow extends StatelessWidget {
  /// Stepslow constructor
  const Stepslow({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        title: 'Stepslow Music Player',
        theme: ThemeData(
            primaryColor: interactiveColor,
            appBarTheme: AppBarTheme(
                color: Colors.transparent,
                elevation: 0,
                iconTheme: IconThemeData(color: unfocusedColor),
                titleTextStyle: const TextStyle(color: blackColor),
                toolbarTextStyle: const TextStyle(color: blackColor)),
            colorScheme: ColorScheme.light(
                primary: interactiveColor,
                secondary: interactiveColor,
                onSecondary: backgroundColor),
            visualDensity: VisualDensity.adaptivePlatformDensity),
        home: const Player(title: 'Player'));
  }
}

/// Stateful app entrypoint.
class Player extends StatefulWidget {
  /// Player constructor
  const Player({Key? key, required this.title}) : super(key: key);

  /// Basic app title
  final String title;

  @override
  State<Player> createState() => _PlayerState();
}

/// State handler.
class _PlayerState extends State<Player> with WidgetsBindingObserver {
  /// Audio player entity
  final AudioPlayer audioPlayer = AudioPlayer(playerId: 'Stepslow Player 1');

  /// Android intent channel entity
  final MethodChannel bridge =
      const MethodChannel('cz.dvorapa.stepslow/sharedPath');

  /// Current playback state
  PlayerState _state = PlayerState.stopped;

  /// Current playback rate
  double _rate = 100.0;

  /// Device volume
  int volume = 50;

  /// Device volume before change
  int _preCoverVolume = 50;

  /// Device volume before mute
  int preMuteVolume = 50;

  /// Device volume before fade
  int _preFadeVolume = 0;

  /// Current playback position
  Duration _position = _emptyDuration;

  /// Position to switch songs
  Duration fadePosition = _emptyDuration;

  /// Playback song from last run
  String? lastSongPath;

  /// Current playback mode
  String _mode = 'loop';

  /// Current playback set
  String _set = 'random';

  late Orientation _orientation;

  /// False if [volume] picker should be hidden
  bool _showVolumePicker = false;

  /// False if [_showVolumePicker] was false at last redraw
  bool _preCoverVolumePicker = false;

  /// Timer to release [_showVolumePicker]
  Timer? _volumeCoverTimer;

  /// Prelude length before playback
  int _introLength = 0;

  /// Random generator to shuffle queue after startup
  final Random random = Random();

  /// History of page transitions
  List<int> pageHistory = [2];

  /// [PageView] controller
  final PageController _controller =
      PageController(initialPage: 2, keepPage: false);

  /// Current playback source
  Source source = _sources[0];

  /// Current playback folder
  String folder = '/storage/emulated/0/Music';

  /// Chosen playback folder
  String chosenFolder = '/storage/emulated/0/Music';

  /// Current playback song
  SongModel? song;

  /// Playback song before change
  SongModel? _previousSong;

  /// Current song index in queue
  int index = 0;

  /// Current song duration
  Duration duration = _emptyDuration;

  /// Source cover stack completer
  int _coversComplete = 0;

  /// File containing album artwork paths YAML map
  File? _coversFile;

  /// YAML map of album artwork paths
  List<String> _coversYaml = ['---'];

  /// Map representation of album artwork paths YAML map
  Map<String, int> _coversMap = {};

  /// Queue completer
  int _queueComplete = 0;

  /// Queue completer
  int _tempQueueComplete = 0;

  /// Song stack completer
  int _songsComplete = 0;

  /// Source stack completer
  int _browseComplete = 0;

  /// Source song stack completer
  int _browseSongsComplete = 0;

  /// Current playback queue
  final List<SongModel> queue = [];

  /// Current playback queue
  final List<SongModel> _tempQueue = [];

  /// Stack of available songs
  final List<SongModel> _songs = [];

  /// Text to speech timer
  Timer? _ttsTimer;

  /// Fade timer
  Timer? _fadeTimer;

  /// Initializes [song] playback
  void onPlay({bool quiet = false}) {
    if (_state == PlayerState.paused || quiet) {
      audioPlayer.resume();
    } else {
      setState(() => song = queue[index]);
      final String songPath = song!.data;
      if (_introLength != 0) {
        onStop(quiet: true);
        audioPlayer.setSourceDeviceFile(songPath);
      }
      final List<int> range = [for (int i = _introLength + 1; i > 0; i--) i];
      _ttsTimer?.cancel();
      if (range.isEmpty) {
        audioPlayer.play(DeviceFileSource(songPath));
      } else {
        _ttsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (range.length > 1) {
            FlutterBeep.playSysSound(Platform.isAndroid ? 24 : 1052);
            range.removeAt(0);
          } else if (range.length == 1) {
            range.removeAt(0);
          } else {
            audioPlayer.play(DeviceFileSource(songPath));
            _ttsTimer!.cancel();
          }
        });
      }
      setState(() => lastSongPath = songPath);
      _setValue('lastSongPath', songPath);
    }
    onRate(_rate);
    if (!quiet) setState(() => _state = PlayerState.playing);
    Wakelock.enable();
  }

  /// Changes [song] according to given [newIndex]
  void onChange(int newIndex) {
    onPause(quiet: true);
    final int available = queue.length;
    setState(() {
      if (newIndex < 0) {
        index = newIndex + available;
        if (_set == 'random' && queue.length > 2) {
          queue.shuffle();
          while (song == queue[index]) queue.shuffle();
        }
      } else if (newIndex >= available) {
        index = newIndex - available;
        if (_set == 'random' && queue.length > 2) {
          queue.shuffle();
          while (song == queue[index]) queue.shuffle();
        }
      } else {
        index = newIndex;
      }
    });
    if (_state == PlayerState.playing) {
      onPlay();
    } else {
      onStop();
      setState(() {
        song = queue.isNotEmpty ? queue[index] : null;
        _position = _emptyDuration;
        if (song != null) duration = Duration(milliseconds: song!.duration!);
      });
      if (song != null) {
        final String songPath = song!.data;
        setState(() => lastSongPath = songPath);
        _setValue('lastSongPath', songPath);
      }
    }
  }

  /// Pauses [song] playback
  void onPause({bool quiet = false}) {
    _ttsTimer?.cancel();
    audioPlayer.pause();
    if (!quiet) setState(() => _state = PlayerState.paused);
    if (_preFadeVolume != 0) {
      _fadeTimer!.cancel();
      onChange(index + 1);
      onVolume(_preFadeVolume);
      setState(() => _preFadeVolume = 0);
    }
  }

  /// Shuts player down and resets its state
  void onStop({bool quiet = false}) {
    audioPlayer.stop();
    setState(() {
      if (!quiet) {
        duration = _emptyDuration;
        _position = _emptyDuration;
      }
      _state = PlayerState.stopped;
    });
    Wakelock.disable();
  }

  /// Changes [folder] according to given
  void onFolder(String newFolder) {
    if (folder != newFolder) {
      queue.clear();
      setState(() {
        index = 0;
        _queueComplete = 0;
      });
      if (!_bad.contains(_songsComplete)) {
        for (final SongModel asong in _songs) {
          if (File(asong.data).parent.path == newFolder) {
            if (_set != 'random' || [0, 1].contains(_queueComplete)) {
              queue.add(asong);
            } else {
              queue.insert(1 + random.nextInt(_queueComplete), asong);
            }
            setState(() => ++_queueComplete);

            if (_queueComplete == 1) {
              onRate(100.0);
              onChange(index);
            }
          }
        }
        if (_queueComplete > 0) {
          setState(() => _queueComplete = -1);
        } else {
          onStop();
          setState(() => song = null);
          if (_controller.page! > .1) _pickFolder();
        }
      }
      setState(() {
        folder = newFolder;
        chosenFolder = newFolder;
        _introLength = 0;
      });
    }
  }

  /// Creates temporary queue list
  void getTempQueue(String tempFolder) {
    if (chosenFolder != tempFolder) {
      setState(() {
        chosenFolder = tempFolder;
        _tempQueueComplete = 0;
      });
      _tempQueue.clear();
      if (!_bad.contains(_songsComplete)) {
        for (final SongModel asong in _songs) {
          if (File(asong.data).parent.path == tempFolder) {
            _tempQueue.add(asong);
            setState(() => ++_tempQueueComplete);
          }
        }
      }
      setState(() => _tempQueueComplete = -1);
    }
  }

  /// Initializes shared or saved [song] playback
  Future<void> loadSpecificSong() async {
    final String? sharedPath = await bridge.invokeMethod('openSharedPath');
    final String? path = sharedPath ?? lastSongPath;
    if (path != null && path != song?.data) {
      final String newFolder = File(path).parent.path;
      final Source newSource =
          _sources.firstWhereOrNull(newFolder.startsWith) ?? source;
      if (source != newSource) setState(() => source = newSource);
      onFolder(newFolder);
      final int newIndex =
          queue.indexWhere((SongModel asong) => asong.data == path);
      onChange(newIndex);
      if (sharedPath != null) onPlay();
    }
  }

  /// Changes playback [_mode] and informs user using given [context]
  void onMode(StatelessElement context) {
    setState(() => _mode = _mode == 'loop' ? 'once' : 'loop');
    _setValue('_mode', _mode);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Theme.of(context).colorScheme.secondary,
        elevation: 0,
        duration: const Duration(seconds: 2),
        content:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
          Text(_mode == 'loop' ? 'playing in a loop ' : 'playing once ',
              style:
                  TextStyle(color: Theme.of(context).colorScheme.onSecondary)),
          Icon(_mode == 'loop' ? Icons.repeat : Icons.trending_flat,
              color: Theme.of(context).colorScheme.onSecondary, size: 20.0)
        ])));
  }

  /// Changes playback [_set] and informs user using given [context]
  void onSet(StatelessElement context) {
    setState(() {
      switch (_set) {
        case '1':
          _set = 'all';
          break;
        case 'all':
          queue.shuffle();

          if (song != null) index = queue.indexOf(song!);
          _set = 'random';

          break;
        default:
          queue.sort((SongModel a, SongModel b) => a.data.compareTo(b.data));

          if (song != null) index = queue.indexOf(song!);
          _set = '1';

          break;
      }
    });
    _setValue('_set', _set);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Theme.of(context).colorScheme.secondary,
        elevation: 0,
        duration: const Duration(seconds: 2),
        content:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
          Icon(_status(_set),
              color: Theme.of(context).colorScheme.onSecondary, size: 20.0),
          Text(_set == '1' ? ' playing 1 song' : ' playing $_set songs',
              style:
                  TextStyle(color: Theme.of(context).colorScheme.onSecondary))
        ])));
  }

  /// Starts to listen seek drag actions
  void onPositionDragStart(
      BuildContext context, DragStartDetails details, Duration duration) {
    final RenderBox slider = context.findRenderObject() as RenderBox;
    final Offset position = slider.globalToLocal(details.globalPosition);
    if (_state == PlayerState.playing) onPause(quiet: true);
    onSeek(position, duration, slider.constraints.biggest.width);
  }

  /// Listens seek drag actions
  void onPositionDragUpdate(
      BuildContext context, DragUpdateDetails details, Duration duration) {
    final RenderBox slider = context.findRenderObject() as RenderBox;
    final Offset position = slider.globalToLocal(details.globalPosition);
    onSeek(position, duration, slider.constraints.biggest.width);
  }

  /// Ends to listen seek drag actions
  void onPositionDragEnd(
      BuildContext context, DragEndDetails details, Duration duration) {
    if (_state == PlayerState.playing) onPlay(quiet: true);
  }

  /// Listens seek tap actions
  void onPositionTapUp(
      BuildContext context, TapUpDetails details, Duration duration) {
    final RenderBox slider = context.findRenderObject() as RenderBox;
    final Offset position = slider.globalToLocal(details.globalPosition);
    onSeek(position, duration, slider.constraints.biggest.width);
  }

  /// Changes [_position] according to seek actions
  void onSeek(Offset position, Duration duration, double width) {
    double newPosition = 0;

    if (position.dx <= 0) {
      newPosition = 0;
    } else if (position.dx >= width) {
      newPosition = width;
    } else {
      newPosition = position.dx;
    }

    setState(() => _position = duration * (newPosition / width));

    audioPlayer.seek(_position * (_rate / 100.0));
  }

  /// Starts to listen [volume] drag actions
  void onVolumeDragStart(BuildContext context, DragStartDetails details) {
    final RenderBox slider = context.findRenderObject() as RenderBox;
    final Offset finger = slider.globalToLocal(details.globalPosition);
    updateVolume(finger, slider.constraints.biggest.height);
  }

  /// Listens [volume] drag actions
  void onVolumeDragUpdate(BuildContext context, DragUpdateDetails details) {
    final RenderBox slider = context.findRenderObject() as RenderBox;
    final Offset finger = slider.globalToLocal(details.globalPosition);
    updateVolume(finger, slider.constraints.biggest.height);
  }

  /// Changes playback [volume] according to given offset
  void updateVolume(Offset finger, double height) {
    double newVolume = 50.0;

    if (finger.dy <= .19 * height) {
      newVolume = 0;
    } else if (finger.dy >= height) {
      newVolume = .81 * height;
    } else {
      newVolume = finger.dy - .19 * height;
    }

    newVolume = 100.0 * (1 - (newVolume / (.81 * height)));
    onVolume(newVolume.floor());
  }

  /// Changes playback [volume] by given
  void onVolume(int newVolume) async {
    if (newVolume > 100) {
      newVolume = 100;
    } else if (newVolume < 0) {
      newVolume = 0;
    }
    VolumeRegulator.setVolume(newVolume);
    setState(() => volume = newVolume);
    _setValue('volume', newVolume);
  }

  /// Changes playback [_rate] by given
  void onRate(double rate) {
    if (rate > 200.0) {
      rate = 200.0;
    } else if (rate < 5.0) {
      rate = 5.0;
    }
    audioPlayer.setPlaybackRate(rate / 100.0);
    setState(() {
      _position = _position * (_rate / rate);
      duration = duration * (_rate / rate);
      _rate = rate;
    });
  }

  /// Switches playback [_prelude]
  void onPrelude() {
    setState(() => _introLength = _introLength == 0 ? 10 : 0);
    if (_introLength == 10) onChange(index);
  }

  /// Switches playback [_state]
  void _changeState() => _state == PlayerState.playing ? onPause() : onPlay();

  /// Shows dialog to pick [source]
  void _pickSource() {
    showDialog(
        context: context,
        builder: (BuildContext context) {
          return SingleChoiceDialog<Source>(
              isDividerEnabled: true,
              items: _sources,
              onSelected: (Source asource) {
                setState(() => source = asource);
                onFolder(asource.root);
              },
              itemBuilder: (Source asource) {
                final Text sourceText = source == asource
                    ? Text(asource.name,
                        style: TextStyle(color: Theme.of(context).primaryColor))
                    : Text(asource.name);
                switch (asource.id) {
                  case -1:
                    return _textButtonLink(
                        icon: Icon(Typicons.social_youtube,
                            color: source == asource
                                ? Theme.of(context).primaryColor
                                : redColor),
                        label: sourceText);
                  case 0:
                    return _textButtonLink(
                        icon: Icon(Icons.phone_iphone,
                            color: source == asource
                                ? Theme.of(context).primaryColor
                                : Theme.of(context)
                                    .textTheme
                                    .bodyText2!
                                    .color!
                                    .withOpacity(.55)),
                        label: sourceText);
                  default:
                    return _textButtonLink(
                        icon: Icon(Icons.sd_card,
                            color: source == asource
                                ? Theme.of(context).primaryColor
                                : Theme.of(context)
                                    .textTheme
                                    .bodyText2!
                                    .color!
                                    .withOpacity(.55)),
                        label: sourceText);
                }
              });
        });
  }

  /// Navigates to folder picker page
  void _pickFolder() => _controller.animateToPage(0,
      duration: _animationDuration, curve: _animationCurve);

  /// Navigates to song picker page
  void _pickSong() => _controller.animateToPage(1,
      duration: _animationDuration, curve: _animationCurve);

  /// Navigates to player main page
  void _returnToPlayer() => _controller.animateToPage(2,
      duration: _animationDuration, curve: _animationCurve);

  /// Navigates to features page
  void _useFeatures() => _controller.animateToPage(3,
      duration: _animationDuration, curve: _animationCurve);

  /// Goes back to the previous page
  bool onBack() {
    final int pageHistoryLength = pageHistory.length;
    if (pageHistoryLength == 1) return true;
    final List<int> oldPageHistory =
        pageHistory.sublist(0, pageHistoryLength - 1);
    _controller
        .animateToPage(pageHistory[pageHistoryLength - 2],
            duration: _animationDuration, curve: _animationCurve)
        .then((_) {
      pageHistory = oldPageHistory;
    }, onError: (error) => print(error.stackTrace));
    return false;
  }

  /// Get cached or preferred value
  void _getSavedValues() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int deviceVolume = await VolumeRegulator.getVolume();

    setState(() {
      lastSongPath = prefs.getString('lastSongPath');
      _mode = prefs.getString('_mode') ?? 'loop';
      _set = prefs.getString('_set') ?? 'random';
      volume = prefs.getInt('volume') ?? deviceVolume;
    });

    await prefs.setString('_mode', _mode);
    await prefs.setString('_set', _set);
    onVolume(volume);
  }

  /// Save cached or preferred value
  Future<void> _setValue(String variable, dynamic value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (value is String) await prefs.setString(variable, value);
    if (value is double) await prefs.setDouble(variable, value);
    if (value is int) await prefs.setInt(variable, value);
  }

  /// Queries album artworks to app cache
  Future<void> _loadCoversMap() async {
    if (_coversComplete == 0) {
      if (!_coversFile!.existsSync()) {
        await _createCoversMap();
      } else {
        try {
          _coversYaml = await _coversFile!.readAsLines();
          _coversMap = Map<String, int>.from(loadYaml(_coversYaml.join('\n')));
          setState(() => _coversComplete = -1);
        } on FileSystemException catch (error) {
          print(error);
          await _createCoversMap();
        } on YamlException catch (error) {
          print(error);
          await _createCoversMap();
        }
      }
    }
  }

  /// Fixes album artworks cache
  Future<void> _fixCoversMap() async {
    if (_coversComplete == -1) {
      setState(() => _coversComplete = 0);
      await _createCoversMap();
    }
  }

  /// Queries album artworks to phone cache
  Future<void> _createCoversMap() async {
    _coversYaml = ['---'];
    _coversMap.clear();
    for (final SongModel asong in _songs) {
      final String songPath = asong.data;
      final String coversPath =
          (_sources.firstWhereOrNull(songPath.startsWith)?.coversPath ??
              _sources[0].coversPath)!;
      final String coverPath = '$coversPath/${songPath.hashCode}.jpg';
      int resultStatus = 0;
      if (!File(coverPath).existsSync()) {
        final int height =
            (MediaQuery.of(context).size.shortestSide * 7 / 10).ceil();
        await FFmpegKit.execute(
                '-i "$songPath" -vf scale="-2:\'min($height,ih)\'":flags=lanczos -an "$coverPath"')
            .then((session) async {
          final returnCode = await session.getReturnCode();
          resultStatus = returnCode!.getValue();
          final String? failStackTrace = await session.getFailStackTrace();
          if (failStackTrace != null && failStackTrace.isNotEmpty)
            print(failStackTrace);
        }, onError: (error) {
          print(error);
          setState(() => _coversComplete = -2);
          return 1;
        });
      }
      _coversMap[songPath] = resultStatus;
      _coversYaml.add('"$songPath": $resultStatus');
      setState(() => ++_coversComplete);
    }
    await _cacheCoversMap();
  }

  /// Writes app cache into a file
  Future<void> _cacheCoversMap() async {
    await _coversFile!.writeAsString(_coversYaml.join('\n'));
    setState(() => _coversComplete = -1);
  }

  /// Gets album artwork from cache
  Image? _getCover(SongModel asong) {
    if (!_bad.contains(_coversComplete)) {
      final String songPath = asong.data;
      if (_coversMap.containsKey(songPath)) {
        if (_coversMap[songPath] == 0) {
          final String coversPath =
              (_sources.firstWhereOrNull(songPath.startsWith)?.coversPath ??
                  _sources[0].coversPath)!;
          final File coverFile = File('$coversPath/${songPath.hashCode}.jpg');
          if (coverFile.existsSync()) {
            return Image.file(coverFile, fit: BoxFit.cover);
            /*} else {
            WidgetsBinding.instance
                .addPostFrameCallback((_) => _fixCover(asong));*/
          }
        }
      } else {
        _fixCoversMap();
      }
    }
    return null;
  }

  /// Fixes album artwork in cache
  Future<void> _fixCover(SongModel asong) async {
    if (_coversComplete == -1) {
      setState(() => _coversComplete = 0);
      final String songPath = asong.data;
      final String coversPath =
          (_sources.firstWhereOrNull(songPath.startsWith)?.coversPath ??
              _sources[0].coversPath)!;
      final String coverPath = '$coversPath/${songPath.hashCode}.jpg';
      int resultStatus = 0;
      final int height =
          (MediaQuery.of(context).size.shortestSide * 7 / 10).ceil();
      await FFmpegKit.execute(
              '-i "$songPath" -vf scale="-2:\'min($height,ih)\'":flags=lanczos -an "$coverPath"')
          .then((session) async {
        final returnCode = await session.getReturnCode();
        resultStatus = returnCode!.getValue();
        final String? failStackTrace = await session.getFailStackTrace();
        if (failStackTrace != null && failStackTrace.isNotEmpty)
          print(failStackTrace);
      }, onError: (error) {
        print(error.stackTrace);
        setState(() => _coversComplete = -2);
        return 1;
      });
      _coversMap[songPath] = resultStatus;
      setState(() => ++_coversComplete);
      _coversYaml = ['---'];
      _coversMap.forEach((String coverSong, int coverStatus) =>
          _coversYaml.add('"$coverSong": $coverStatus'));
      await _cacheCoversMap();
    }
  }

  /// Gets relative urls for [fillBrowse]
  Iterable<int> getRelatives(String root, String path) {
    final int rootLength = root.length;
    String relative = path.substring(rootLength);
    if (relative.startsWith('/')) relative = '${relative.substring(1)}/';
    return '/'.allMatches(relative).map((Match m) => rootLength + m.end);
  }

  /// Fills [browse] stack with given [path]
  void fillBrowse(
      String path,
      String sourceRoot,
      SplayTreeMap<Entry, SplayTreeMap> browse,
      int value,
      ValueChanged<int> valueChanged,
      String type) {
    final Iterable<int> relatives = getRelatives(sourceRoot, path);
    int j = 0;
    String relativeString;
    num length = type == 'song' ? relatives.length - 1 : relatives.length;
    if (length == 0) length = .5;
    while (j < length) {
      relativeString =
          length == .5 ? sourceRoot : path.substring(0, relatives.elementAt(j));
      Entry entry = Entry(relativeString, type);
      if (browse.containsKey(entry)) {
        entry = browse.keys.firstWhere((Entry key) => key == entry);
      } else {
        browse[entry] = SplayTreeMap<Entry, SplayTreeMap>();
        if (value != -2) setState(() => valueChanged(++value));
      }
      if (type == 'song') entry.songs++;
      browse = browse[entry] as SplayTreeMap<Entry, SplayTreeMap>;
      j++;
    }
  }

  @override
  void initState() {
    _getSavedValues();

    audioPlayer.onDurationChanged.listen((Duration d) {
      setState(() => duration = d * (100.0 / _rate));
    });
    audioPlayer.onPositionChanged.listen((Duration p) {
      setState(() => _position = p * (100.0 / _rate));
      if (fadePosition > _emptyDuration &&
          _position > fadePosition &&
          _preFadeVolume == 0 &&
          _state == PlayerState.playing) {
        setState(() => _preFadeVolume = volume);
        _fadeTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (volume > 0) {
            onVolume(volume - 1);
          } else {
            _fadeTimer!.cancel();
            onChange(index + 1);
            onVolume(_preFadeVolume);
            setState(() => _preFadeVolume = 0);
          }
        });
      }
    });
    audioPlayer.onPlayerComplete.listen((_) {
      setState(() => _position = duration);
      if (_mode == 'once' && (_set == '1' || index == queue.length - 1)) {
        onStop();
      } else if (_set == '1') {
        onPlay();
      } else {
        onChange(index + 1);
      }
    });
    /*audioPlayer.onPlayerError.listen((String error) {
      onStop();
      print(error);
    });*/

    VolumeRegulator.volumeStream.listen((int v) {
      setState(() => volume = v);
      _setValue('volume', v);
    });

    _controller.addListener(() {
      final double modulo = _controller.page! % 1;
      if (.9 < modulo || modulo < .1) {
        final int last = pageHistory.last;
        final int page = _controller.page!.round();
        if (last != page) {
          if (page != 2) {
            final int pageHistoryLength = pageHistory.length;
            if (last == 2 && pageHistoryLength != 1) {
              pageHistory.removeRange(1, pageHistoryLength);
            } else {
              pageHistory.remove(page);
            }
          }
          pageHistory.add(page);
        }
      }
    });

    super.initState();

    Permission.storage.request().then((PermissionStatus permissionStatus) {
      if (permissionStatus == PermissionStatus.permanentlyDenied) {
        openAppSettings();
      } else if (permissionStatus == PermissionStatus.denied) {
        SystemChannels.platform.invokeMethod('SystemNavigator.pop');
      }
      // Got permission (read user files and folders)
      checkoutSdCards().listen(_sources.add,
          onDone: () {
            // Got _sources
            Stream<List<SongModel>>.fromFuture(OnAudioQuery().querySongs())
                .expand((List<SongModel> asongs) => asongs)
                .listen((SongModel asong) {
              final String songPath = asong.data;
              // queue
              if (File(songPath).parent.path == folder) {
                if (_set != 'random' || [0, 1].contains(_queueComplete)) {
                  queue.add(asong);
                } else {
                  queue.insert(1 + random.nextInt(_queueComplete), asong);
                }
                setState(() => ++_queueComplete);
                if (_queueComplete == 1) {
                  audioPlayer.setSourceDeviceFile(songPath);
                  setState(() => song = queue[0]);
                }
              }

              if (_sources.any(songPath.startsWith)) {
                // _songs
                _songs.add(asong);
                setState(() => ++_songsComplete);

                // browse
                final Source asource = _sources.firstWhere(songPath.startsWith);
                fillBrowse(
                    songPath,
                    asource.root,
                    asource.browse,
                    _browseSongsComplete,
                    (value) => _browseSongsComplete = value,
                    'song');
              }
            }, onDone: () {
              // Got queue, _songs, browse
              setState(() {
                _queueComplete = _queueComplete > 0 ? -1 : 0;
                _songsComplete = _songsComplete > 0 ? -1 : 0;
                if (_sources.every(
                    (Source asource) => asource.browseFoldersComplete == -1))
                  _browseComplete = -1;
                _browseSongsComplete = _browseSongsComplete > 0 ? -1 : 0;
              });
              if (_songsComplete == -1 &&
                  _coversFile != null &&
                  !_sources.any((Source asource) => asource.coversPath == null))
                _loadCoversMap();
            }, onError: (error) {
              setState(() {
                _queueComplete = -2;
                _songsComplete = -2;
                _browseComplete = -2;
                _browseSongsComplete = -2;
              });
              print(error.stackTrace);
            });

            for (final Source asource in _sources) {
              getFolders(asource.root).listen((String folderPath) {
                fillBrowse(
                    folderPath,
                    asource.root,
                    asource.browse,
                    asource.browseFoldersComplete,
                    (value) => asource.browseFoldersComplete = value,
                    'folder');
              }, onDone: () {
                fillBrowse(
                    asource.root,
                    asource.root,
                    asource.browse,
                    asource.browseFoldersComplete,
                    (value) => asource.browseFoldersComplete = value,
                    'folder');
                // Got folders
                setState(() {
                  asource.browseFoldersComplete = -1;
                  if ((_browseSongsComplete == -1) &&
                      _sources.every((Source asource) =>
                          asource.browseFoldersComplete == -1))
                    _browseComplete = -1;
                });
                loadSpecificSong();
                WidgetsBinding.instance.addObserver(this);
              }, onError: (error) {
                setState(() {
                  _browseComplete = -2;
                  asource.browseFoldersComplete = -2;
                });
                print(error.stackTrace);
              });
            }

            getTemporaryDirectory().then((Directory appCache) {
              for (final Source asource in _sources)
                asource.coversPath = appCache.path;

              if (Platform.isAndroid) {
                Stream<List<Directory>?>.fromFuture(
                        getExternalCacheDirectories())
                    .expand((List<Directory>? extCaches) => extCaches!)
                    .listen((Directory extCache) {
                  final String extCachePath = extCache.path;
                  if (!extCachePath.startsWith(_sources[0])) {
                    _sources.firstWhere(extCachePath.startsWith).coversPath =
                        extCachePath;
                  } else if (_debug) {
                    _sources[0].coversPath = extCachePath;
                  }
                }, onDone: () {
                  // Got coversPath
                  if (_songsComplete == -1 && _coversFile != null)
                    _loadCoversMap();
                }, onError: (error) => print(error.stackTrace));
              } else {
                if (_songsComplete == -1 && _coversFile != null)
                  _loadCoversMap();
              }
            }, onError: (error) => print(error.stackTrace));
          },
          onError: (error) => print(error.stackTrace));
    }, onError: (error) => print(error.stackTrace));

    /*Stream<List<InternetAddress>>.fromFuture(
            InternetAddress.lookup('youtube.com'))
        .expand((List<InternetAddress> addresses) => addresses)
        .firstWhere((InternetAddress address) => address.rawAddress.isNotEmpty)
        .then((_) => _sources.add(Source('', -1)),
            onError: (error) => print(error.stackTrace));*/
    // Got YouTube

    getApplicationSupportDirectory().then((Directory appData) {
      _coversFile = File('${appData.path}/covers.yaml');

      if (Platform.isAndroid && _debug) {
        late StreamSubscription<Directory> extDataStream;
        extDataStream =
            Stream<List<Directory>?>.fromFuture(getExternalStorageDirectories())
                .expand((List<Directory>? extDatas) => extDatas!)
                .listen((Directory extData) {
          final String extDataPath = extData.path;
          if (extDataPath.startsWith(_sources[0])) {
            _coversFile = File('$extDataPath/covers.yaml');
            // Got _coversFile
            if (_songsComplete == -1 &&
                !_sources.any((Source asource) => asource.coversPath == null))
              _loadCoversMap();
            extDataStream.cancel();
          }
        }, onError: (error) => print(error.stackTrace));
      } else {
        if (_songsComplete == -1 &&
            !_sources.any((Source asource) => asource.coversPath == null))
          _loadCoversMap();
      }
    }, onError: (error) => print(error.stackTrace));
  }

  @override
  void dispose() {
    audioPlayer.release();
    FFmpegKit.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState appState) {
    if (appState == AppLifecycleState.resumed) loadSpecificSong();
  }

  @override
  Widget build(BuildContext context) {
    if (_preCoverVolume != volume) {
      _showVolumePicker = true;
      _preCoverVolume = volume;
      _volumeCoverTimer?.cancel();
      _volumeCoverTimer = Timer(_defaultDuration, () {
        setState(() => _showVolumePicker = false);
      });
    }
    if (_previousSong != song) {
      _showVolumePicker = false;
      _previousSong = song;
      _volumeCoverTimer?.cancel();
    }
    if (_preCoverVolumePicker != _showVolumePicker) {
      _volumeCoverTimer?.cancel();
      _volumeCoverTimer = Timer(_defaultDuration, () {
        setState(() => _showVolumePicker = false);
      });
    }
    _preCoverVolumePicker = _showVolumePicker;
    _orientation = MediaQuery.of(context).orientation;
    return Material(
        child: PageView(
            controller: _controller,
            physics: const BouncingScrollPhysics(),
            children: <WillPopScope>[
          // folders
          WillPopScope(
              onWillPop: () => Future<bool>.sync(onBack),
              child: Scaffold(
                  appBar: AppBar(
                      leading: IconButton(
                          tooltip: 'Change source',
                          onPressed: _pickSource,
                          icon: _sourceButton(
                              source.id,
                              Theme.of(context)
                                  .textTheme
                                  .bodyText2!
                                  .color!
                                  .withOpacity(.55))),
                      title: Tooltip(
                          message: 'Change source',
                          child: InkWell(
                              onTap: _pickSource, child: Text(source.name))),
                      actions: _showContents(this)),
                  body: _folderPicker(this))),
          // songs
          WillPopScope(
              onWillPop: () => Future<bool>.sync(onBack),
              child: Scaffold(
                  appBar: AppBar(
                      leading: chosenFolder != folder
                          ? IconButton(
                              onPressed: _pickFolder,
                              tooltip: 'Pick different folder',
                              icon: const Icon(Icons.navigate_before))
                          : IconButton(
                              onPressed: _pickFolder,
                              tooltip: 'Pick different folder',
                              icon: queue.isNotEmpty
                                  ? const Icon(Typicons.folder_open)
                                  : Icon(Icons.create_new_folder_outlined,
                                      color: Theme.of(context)
                                          .textTheme
                                          .bodyText2!
                                          .color!
                                          .withOpacity(.55))),
                      title: _navigation(this)),
                  body: _songPicker(this),
                  floatingActionButton: Align(
                      alignment: const Alignment(.8, .8),
                      child: Transform.scale(
                          scale: 1.1,
                          child: chosenFolder != folder
                              ? FloatingActionButton(
                                  onPressed: () {
                                    onFolder(chosenFolder);
                                    if (queue.isNotEmpty) {
                                      setState(() => index = 0);
                                      onPlay();
                                      _returnToPlayer();
                                    }
                                  },
                                  tooltip: _tempQueueComplete == -1
                                      ? 'Play chosen folder'
                                      : 'Loading...',
                                  shape: _orientation == Orientation.portrait
                                      ? const _CubistShapeB()
                                      : const _CubistShapeD(),
                                  elevation: 6.0,
                                  child: _tempQueueComplete == -1
                                      ? const Icon(Icons.play_arrow, size: 32.0)
                                      : SizedBox(
                                          width: 22.0,
                                          height: 22.0,
                                          child: CircularProgressIndicator(
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                      Theme.of(context)
                                                          .colorScheme
                                                          .onSecondary))))
                              : _play(this, 6.0, 32.0, () {
                                  _changeState();
                                  if (_state == PlayerState.playing)
                                    _returnToPlayer();
                                }))))),
          // player
          WillPopScope(
              onWillPop: () => Future<bool>.sync(onBack),
              child: Scaffold(
                  appBar: AppBar(
                      leading: IconButton(
                          onPressed: _pickFolder,
                          tooltip: 'Pick different folder',
                          icon: queue.isNotEmpty
                              ? const Icon(Typicons.folder_open)
                              : Icon(Icons.create_new_folder_outlined,
                                  color: Theme.of(context)
                                      .textTheme
                                      .bodyText2!
                                      .color!
                                      .withOpacity(.55))),
                      actions: <IconButton>[
                        IconButton(
                            onPressed: _useFeatures,
                            tooltip: 'Try special features',
                            icon: Icon(Icons.auto_fix_normal,
                                color: Theme.of(context)
                                    .textTheme
                                    .bodyText2!
                                    .color!
                                    .withOpacity(.55)))
                      ]),
                  body: _orientation == Orientation.portrait
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: <Flexible>[
                              Flexible(
                                  flex: 17,
                                  child: FractionallySizedBox(
                                      widthFactor: .45,
                                      child: _playerSquared(this))),
                              Flexible(
                                  flex: 11,
                                  child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        _introLength == 0
                                            ? const SizedBox.shrink()
                                            : GestureDetector(
                                                onDoubleTap: onPrelude,
                                                child: FractionallySizedBox(
                                                    heightFactor: _heightFactor(
                                                        1,
                                                        volume,
                                                        wave(song?.title ?? 'zapaz')
                                                            .first),
                                                    child: Container(
                                                        alignment:
                                                            Alignment.center,
                                                        padding: const EdgeInsets
                                                                .symmetric(
                                                            horizontal: 12.0),
                                                        color: redColor,
                                                        child: Text(
                                                            '$_introLength s',
                                                            style: TextStyle(
                                                                color: Theme.of(
                                                                        context)
                                                                    .scaffoldBackgroundColor))))),
                                        Expanded(child: _playerOblong(this))
                                      ])),
                              Flexible(
                                  flex: 20,
                                  child: Container(
                                      padding: const EdgeInsets.fromLTRB(
                                          16.0, 12.0, 16.0, 0),
                                      color: Theme.of(context).primaryColor,
                                      child: Theme(
                                          data: ThemeData.from(
                                              colorScheme: Theme.of(context)
                                                  .colorScheme
                                                  .copyWith(
                                                      secondary: Theme.of(
                                                              context)
                                                          .scaffoldBackgroundColor,
                                                      onSecondary:
                                                          Theme.of(context)
                                                              .primaryColor,
                                                      brightness:
                                                          Brightness.dark)),
                                          child: _playerControl(this))))
                            ])
                      : Column(children: <Flexible>[
                          Flexible(
                              flex: 3,
                              child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceEvenly,
                                  children: <Widget>[
                                    SizedBox(
                                        width:
                                            MediaQuery.of(context).size.width *
                                                .37,
                                        child: Theme(
                                            data: Theme.of(context).copyWith(
                                                textTheme: Theme.of(context)
                                                    .textTheme
                                                    .apply(
                                                        bodyColor:
                                                            Theme.of(context)
                                                                .primaryColor),
                                                iconTheme: IconThemeData(
                                                    color: Theme.of(context)
                                                        .primaryColor)),
                                            child: _playerControl(this))),
                                    _playerSquared(this)
                                  ])),
                          Flexible(
                              flex: 2,
                              child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: <Widget>[
                                    FractionallySizedBox(
                                        heightFactor: _heightFactor(1, volume,
                                            wave(song?.title ?? 'zapaz').first),
                                        child: Container(
                                            alignment: Alignment.center,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12.0),
                                            color: _position == _emptyDuration
                                                ? Theme.of(context)
                                                    .primaryColor
                                                    .withOpacity(.7)
                                                : Theme.of(context)
                                                    .primaryColor,
                                            child: Text(
                                                _timeInfo(
                                                    _queueComplete, _position),
                                                style: TextStyle(
                                                    color: Theme.of(context)
                                                        .scaffoldBackgroundColor,
                                                    fontWeight:
                                                        FontWeight.bold)))),
                                    _introLength == 0
                                        ? const SizedBox.shrink()
                                        : GestureDetector(
                                            onDoubleTap: onPrelude,
                                            child: FractionallySizedBox(
                                                heightFactor: _heightFactor(
                                                    1,
                                                    volume,
                                                    wave(song?.title ?? 'zapaz')
                                                        .first),
                                                child: Container(
                                                    alignment: Alignment.center,
                                                    padding: const EdgeInsets
                                                            .symmetric(
                                                        horizontal: 12.0),
                                                    color: redColor,
                                                    child: Text(
                                                        '$_introLength s',
                                                        style: TextStyle(
                                                            color: Theme.of(
                                                                    context)
                                                                .scaffoldBackgroundColor))))),
                                    Expanded(child: _playerOblong(this)),
                                    FractionallySizedBox(
                                        heightFactor: _heightFactor(1, volume,
                                            wave(song?.title ?? 'zapaz').last),
                                        child: Container(
                                            alignment: Alignment.center,
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12.0),
                                            color: _position == duration &&
                                                    duration != _emptyDuration
                                                ? Theme.of(context).primaryColor
                                                : Theme.of(context)
                                                    .primaryColor
                                                    .withOpacity(.7),
                                            child: Text(_timeInfo(_queueComplete, fadePosition == _emptyDuration ? duration : fadePosition),
                                                style: TextStyle(
                                                    color: (fadePosition == _emptyDuration) && (_rate == 100.0)
                                                        ? Theme.of(context)
                                                            .scaffoldBackgroundColor
                                                        : redColor,
                                                    fontWeight:
                                                        (fadePosition == _emptyDuration) &&
                                                                (_rate == 100.0)
                                                            ? FontWeight.normal
                                                            : FontWeight.bold))))
                                  ]))
                        ]))),
          // features
          WillPopScope(
              onWillPop: () => Future<bool>.sync(onBack),
              child: Scaffold(
                  backgroundColor: Theme.of(context).primaryColor,
                  appBar: AppBar(
                      leading: IconButton(
                          onPressed: _returnToPlayer,
                          tooltip: 'Back to player',
                          icon: Icon(Icons.navigate_before,
                              color:
                                  Theme.of(context).colorScheme.onSecondary)),
                      actions: <IconButton>[
                        IconButton(
                            onPressed: () => showDialog(
                                context: context,
                                builder: (BuildContext context) {
                                  return AlertDialog(
                                      titlePadding: const EdgeInsets.fromLTRB(
                                          24.0, 12.0, 24.0, 0),
                                      titleTextStyle:
                                          Theme.of(context).textTheme.subtitle1,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                              horizontal: 24.0, vertical: 0),
                                      title: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: <Text>[
                                            const Text(Pubspec.name,
                                                style:
                                                    TextStyle(fontSize: 32.0)),
                                            Text(
                                                '${Pubspec.description}\nversion ${Pubspec.version}, build ${Pubspec.versionBuild}\nby @dvorapa',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                    color: unfocusedColor,
                                                    fontSize: 13.0))
                                          ]
                                              .map((Text textWidget) => Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(vertical: 5.0),
                                                  child: textWidget))
                                              .toList()),
                                      content: _appInfoLinks(this),
                                      actions: <TextButton>[
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            child: const Text('Close',
                                                style:
                                                    TextStyle(fontSize: 16.0)))
                                      ]);
                                }),
                            tooltip: 'Open app info',
                            icon: Icon(Icons.info_outline_rounded,
                                color:
                                    Theme.of(context).colorScheme.onSecondary))
                      ]),
                  body: Column(children: <Widget>[
                    Padding(
                        padding: _orientation == Orientation.portrait
                            ? const EdgeInsets.fromLTRB(40.0, 20.0, 20.0, 40.0)
                            : const EdgeInsets.fromLTRB(40.0, 0, 20.0, 20.0),
                        child: Row(children: <Widget>[
                          Text('Special',
                              style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onSecondary,
                                  fontSize: 25.0,
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(width: 10.0),
                          Text('Features',
                              style: TextStyle(
                                  color:
                                      Theme.of(context).colorScheme.onSecondary,
                                  fontSize: 25.0))
                        ])),
                    Expanded(
                        child: DecoratedBox(
                            decoration: ShapeDecoration(
                                color:
                                    Theme.of(context).colorScheme.onSecondary,
                                shape: const _CubistShapeE()),
                            child: Theme(
                                data: Theme.of(context).copyWith(
                                    iconTheme: IconThemeData(
                                        color: Theme.of(context)
                                            .textTheme
                                            .bodyText2!
                                            .color!
                                            .withOpacity(.55)),
                                    textTheme: Theme.of(context)
                                        .textTheme
                                        .apply(
                                            bodyColor: Theme.of(context)
                                                .textTheme
                                                .bodyText2!
                                                .color!
                                                .withOpacity(.55))),
                                child: Padding(
                                    padding: EdgeInsets.all(
                                        _orientation == Orientation.portrait ? 40.0 : 20.0),
                                    child: _specialFeaturesList(this)))))
                  ])))
        ]));
  }
}

/// Picks appropriate icon according to [sourceId] given
Icon _sourceButton(int sourceId, Color darkColor) {
  switch (sourceId) {
    case -1:
      return const Icon(Typicons.social_youtube, color: redColor);
    case 0:
      return Icon(Icons.phone_iphone, color: darkColor);
    default:
      return Icon(Icons.sd_card, color: darkColor);
  }
}

/// Shows standardized icon list item
Row _textButtonLink({required Icon icon, required Text label}) {
  return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[icon, const SizedBox(width: 12.0), label]);
}

/// Shows icon according to current [chosenFolder]
List<IconButton> _showContents(_PlayerState parent) {
  List<IconButton> actionsList = [];
  if (parent._tempQueueComplete == -1 && parent._tempQueue.isNotEmpty) {
    actionsList.add(IconButton(
        onPressed: parent._pickSong,
        tooltip: 'Pick song',
        icon: Icon(Icons.playlist_play_rounded,
            size: 30.0,
            color: Theme.of(parent.context)
                .textTheme
                .bodyText2!
                .color!
                .withOpacity(.55))));
  }
  return actionsList;
}

/// Renders folder list
Widget _folderPicker(_PlayerState parent) {
  if (parent.source.id == -1)
    return const Center(child: Text('Not yet supported!'));

  final int abrowseComplete = parent._browseComplete;
  final SplayTreeMap<Entry, SplayTreeMap> browse = parent.source.browse;
  if (abrowseComplete == 0) {
    return Center(
        child:
            Text('No folders found', style: TextStyle(color: unfocusedColor)));
  } else if (abrowseComplete == -2) {
    return const Center(child: Text('Unable to retrieve folders!'));
  }
  return ListView.builder(
      /*key: PageStorageKey<int>(browse.hashCode),*/
      padding: const EdgeInsets.all(16.0),
      itemCount: browse.length,
      itemBuilder: (BuildContext context, int i) =>
          _folderTile(parent, browse.entries.elementAt(i)));
}

/// Renders folder list tile
Widget _folderTile(parent, MapEntry<Entry, SplayTreeMap> tree) {
  final SplayTreeMap<Entry, SplayTreeMap> children =
      tree.value as SplayTreeMap<Entry, SplayTreeMap>;
  final Entry entry = tree.key;
  final int entrySongs = entry.songs;
  String songCount = '';
  switch (entrySongs) {
    case 0:
      songCount = '';
      break;
    case 1:
      songCount = '1 song';
      break;
    default:
      songCount = '$entrySongs songs';
      break;
  }
  final String entryPath = entry.path;
  final String entryName = entry.name;
  if (children.isNotEmpty) {
    return ExpansionTile(
        /*key: PageStorageKey<MapEntry>(tree),*/
        key: UniqueKey(),
        initiallyExpanded: parent.chosenFolder.contains(entryPath),
        onExpansionChanged: (_) => parent.getTempQueue(entryPath),
        childrenPadding: const EdgeInsets.only(left: 16.0),
        title: Text(entryName,
            style: TextStyle(
                color: parent.folder == entryPath
                    ? Theme.of(parent.context).primaryColor
                    : Theme.of(parent.context).textTheme.bodyText2!.color)),
        subtitle: Text(songCount,
            style: TextStyle(
                fontSize: 10.0,
                color: parent.folder == entryPath
                    ? Theme.of(parent.context).primaryColor
                    : Theme.of(parent.context)
                        .textTheme
                        .bodyText2!
                        .color!
                        .withOpacity(.55))),
        children: children.entries
            .map((MapEntry<Entry, SplayTreeMap> tree) =>
                _folderTile(parent, tree))
            .toList());
  }
  return ListTile(
      selected: parent.folder == entryPath,
      onTap: () {
        parent
          ..getTempQueue(entryPath)
          .._pickSong();
      },
      title: entryName.isEmpty
          ? Align(
              alignment: Alignment.centerLeft,
              child: Icon(Icons.home,
                  color: parent.folder == entryPath
                      ? Theme.of(parent.context).primaryColor
                      : unfocusedColor))
          : Text(entryName),
      subtitle: Text(songCount, style: const TextStyle(fontSize: 10.0)));
}

/// Renders play/pause button
Widget _play(_PlayerState parent, double elevation, double iconSize,
    VoidCallback onPressed) {
  return Builder(builder: (BuildContext context) {
    final ShapeBorder shape = parent._orientation == Orientation.portrait
        ? const _CubistShapeB()
        : const _CubistShapeD();
    if (parent._queueComplete == 0) {
      return FloatingActionButton(
          onPressed: () {},
          tooltip: 'Loading...',
          shape: shape,
          elevation: elevation,
          child: SizedBox(
              width: iconSize - 10.0,
              height: iconSize - 10.0,
              child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).colorScheme.onSecondary))));
    } else if (parent._queueComplete == -2) {
      return FloatingActionButton(
          onPressed: () {},
          tooltip: 'Unable to retrieve songs!',
          shape: shape,
          elevation: elevation,
          child: Icon(Icons.close, size: iconSize));
    }
    return FloatingActionButton(
        onPressed: onPressed,
        tooltip: parent._state == PlayerState.playing ? 'Pause' : 'Play',
        shape: shape,
        elevation: elevation,
        child: Icon(
            parent._state == PlayerState.playing
                ? Icons.pause
                : Icons.play_arrow,
            size: iconSize));
  });
}

/// Handles squared player section
AspectRatio _playerSquared(_PlayerState parent) {
  return AspectRatio(
      aspectRatio: 8 / 7,
      child: Theme(
          data: ThemeData(
              textTheme: Theme.of(parent.context)
                  .textTheme
                  .apply(bodyColor: unfocusedColor),
              iconTheme: IconThemeData(color: unfocusedColor)),
          child: Material(
              clipBehavior: Clip.antiAlias,
              elevation: 2.0,
              shape: parent._orientation == Orientation.portrait
                  ? const _CubistShapeA()
                  : const _CubistShapeC(),
              child: _volumeCover(parent))));
}

/// Renders rate selector
Widget _ratePicker(parent) {
  return Builder(builder: (BuildContext context) {
    String message = 'Set player speed';
    GestureTapCallback onTap = () {};
    final TextStyle textStyle = TextStyle(
        fontSize: 30, color: Theme.of(context).textTheme.bodyText2!.color);
    if (parent._rate != 100.0) {
      message = 'Reset player speed';
      onTap = () => parent.onRate(100.0);
    }
    return Center(
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      Tooltip(
          message: message,
          child: InkWell(
              onTap: onTap,
              child: Text('${parent._rate.truncate()}', style: textStyle))),
      Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <IconButton>[
            IconButton(
                onPressed: () => parent.onRate(parent._rate + 5.0),
                tooltip: 'Speed up',
                icon: const Icon(Icons.keyboard_arrow_up, size: 30)),
            IconButton(
                onPressed: () => parent.onRate(parent._rate - 5.0),
                tooltip: 'Slow down',
                icon: const Icon(Icons.keyboard_arrow_down, size: 30))
          ]),
      Text('%', style: textStyle)
    ]));
  });
}

/// Renders album artwork or volume selector
Widget _volumeCover(parent) {
  if (parent._showVolumePicker == true) {
    String message = 'Hide volume selector';
    GestureTapCallback onTap = () {
      parent.setState(() => parent._showVolumePicker = false);
    };
    const TextStyle textStyle = TextStyle(fontSize: 30);
    if (parent.volume != 0) {
      message = 'Mute';
      parent.setState(() => parent.preMuteVolume = parent.volume);
      onTap = () => parent.onVolume(0);
    } else {
      message = 'Unmute';
      onTap = () => parent.onVolume(parent.preMuteVolume);
    }
    return Center(
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      Tooltip(
          message: message,
          child: InkWell(
              onTap: onTap, child: Text('${parent.volume}', style: textStyle))),
      Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <IconButton>[
            IconButton(
                onPressed: () => parent.onVolume(parent.volume + 3),
                tooltip: 'Louder',
                icon: const Icon(Icons.keyboard_arrow_up, size: 30)),
            IconButton(
                onPressed: () => parent.onVolume(parent.volume - 3),
                tooltip: 'Quieter',
                icon: const Icon(Icons.keyboard_arrow_down, size: 30))
          ]),
      const Text('%', style: textStyle)
    ]));
  }
  Widget? cover;
  if (parent.song != null) cover = parent._getCover(parent.song);
  cover ??= const Icon(Icons.music_note, size: 48.0);
  return Tooltip(
      message: 'Show volume selector',
      child: InkWell(
          onTap: () {
            parent.setState(() => parent._showVolumePicker = true);
          },
          child: cover));
}

/// Renders prelude length selector
Widget _preludePicker(parent) {
  return Builder(builder: (BuildContext context) {
    String message = 'Reset intro length';
    if (parent._introLength == 0) message = 'Set intro length';
    final TextStyle textStyle = TextStyle(
        fontSize: 30, color: Theme.of(context).textTheme.bodyText2!.color);
    return Center(
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      Tooltip(
          message: message,
          child: InkWell(
              onTap: () {
                parent.setState(() =>
                    parent._introLength = parent._introLength == 0 ? 10 : 0);
              },
              child: Text('${parent._introLength}', style: textStyle))),
      Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <IconButton>[
            IconButton(
                onPressed: () {
                  parent.setState(() => parent._introLength += 5);
                },
                tooltip: 'Add more',
                icon: const Icon(Icons.keyboard_arrow_up, size: 30)),
            IconButton(
                onPressed: () {
                  if (parent._introLength >= 5) {
                    parent.setState(() => parent._introLength -= 5);
                  }
                },
                tooltip: 'Shorten',
                icon: const Icon(Icons.keyboard_arrow_down, size: 30))
          ]),
      Text('s', style: textStyle)
    ]));
  });
}

/// Renders fade position selector
Widget _fadePositionPicker(parent) {
  return Builder(builder: (BuildContext context) {
    String message = 'Reset fade position';
    if (parent.fadePosition == _emptyDuration) message = 'Set fade position';
    final TextStyle textStyle = TextStyle(
        fontSize: 30, color: Theme.of(context).textTheme.bodyText2!.color);
    return Center(
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      Tooltip(
          message: message,
          child: InkWell(
              onTap: () {
                parent.setState(() => parent.fadePosition =
                    parent.fadePosition == _emptyDuration
                        ? const Duration(seconds: 90)
                        : _emptyDuration);
              },
              child: Text(
                  '${parent.fadePosition.inMinutes}:${zero(parent.fadePosition.inSeconds % 60)}',
                  style: textStyle))),
      Column(mainAxisAlignment: MainAxisAlignment.center, children: <
          IconButton>[
        IconButton(
            onPressed: () {
              parent.setState(() => parent.fadePosition += _defaultDuration);
            },
            tooltip: 'Lengthen',
            icon: const Icon(Icons.keyboard_arrow_up, size: 30)),
        IconButton(
            onPressed: () {
              if (parent.fadePosition >= _defaultDuration) {
                parent.setState(() => parent.fadePosition -= _defaultDuration);
              }
            },
            tooltip: 'Shorten',
            icon: const Icon(Icons.keyboard_arrow_down, size: 30))
      ])
    ]));
  });
}

/// Handles oblong player section
Widget _playerOblong(parent) {
  return Builder(builder: (BuildContext context) {
    /*return Tooltip(
        message: '''
Drag position horizontally to change it
Drag curve vertically to change speed
Double tap to add intro''',
        showDuration: _defaultDuration,
        child: GestureDetector(*/
    return GestureDetector(
        onHorizontalDragStart: (DragStartDetails details) {
          parent.onPositionDragStart(
              context,
              details,
              _bad.contains(parent._queueComplete)
                  ? _defaultDuration
                  : parent.duration);
        },
        onHorizontalDragUpdate: (DragUpdateDetails details) {
          parent.onPositionDragUpdate(
              context,
              details,
              _bad.contains(parent._queueComplete)
                  ? _defaultDuration
                  : parent.duration);
        },
        onHorizontalDragEnd: (DragEndDetails details) {
          parent.onPositionDragEnd(
              context,
              details,
              _bad.contains(parent._queueComplete)
                  ? _defaultDuration
                  : parent.duration);
        },
        onTapUp: (TapUpDetails details) {
          parent.onPositionTapUp(
              context,
              details,
              _bad.contains(parent._queueComplete)
                  ? _defaultDuration
                  : parent.duration);
        },
        onVerticalDragStart: (DragStartDetails details) =>
            parent.onVolumeDragStart(context, details),
        onVerticalDragUpdate: (DragUpdateDetails details) =>
            parent.onVolumeDragUpdate(context, details),
        onDoubleTap: parent.onPrelude,
        child: CustomPaint(
            size: Size.infinite,
            painter: CubistWave(
                _bad.contains(parent._queueComplete)
                    ? 'zapaz'
                    : parent.song!.title,
                _bad.contains(parent._queueComplete)
                    ? _defaultDuration
                    : parent.duration,
                parent._position,
                parent.volume,
                Theme.of(context).primaryColor,
                parent.fadePosition)));
  });
}

/// Handles control player section
Widget _playerControl(_PlayerState parent) {
  return Builder(builder: (BuildContext context) {
    if (parent._orientation == Orientation.portrait) {
      return Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Text>[
                  Text(_timeInfo(parent._queueComplete, parent._position),
                      style: TextStyle(
                          color: Theme.of(context).textTheme.bodyText2!.color,
                          fontWeight: FontWeight.bold)),
                  Text(
                      _timeInfo(
                          parent._queueComplete,
                          parent.fadePosition == _emptyDuration
                              ? parent.duration
                              : parent.fadePosition),
                      style: TextStyle(
                          color: (parent.fadePosition == _emptyDuration) &&
                                  (parent._rate == 100.0)
                              ? Theme.of(context).textTheme.bodyText2!.color
                              : redColor,
                          fontWeight: (parent.fadePosition == _emptyDuration) &&
                                  (parent._rate == 100.0)
                              ? FontWeight.normal
                              : FontWeight.bold))
                ]),
            _title(parent),
            _artist(parent),
            _mainControl(parent),
            _minorControl(parent)
          ]);
    }
    return Column(children: <Widget>[
      _mainControl(parent),
      _minorControl(parent),
      Expanded(
          child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[_artist(parent), _title(parent)]))
    ]);
  });
}

/// Renders current song title
Widget _title(_PlayerState parent) {
  return Builder(builder: (BuildContext context) {
    if (parent._queueComplete == 0) {
      return Text('Empty queue',
          style: TextStyle(
              color: Theme.of(context).textTheme.bodyText2!.color,
              fontSize: 15.0));
    } else if (parent._queueComplete == -2) {
      return Text('Unable to retrieve songs!',
          style: TextStyle(
              color: Theme.of(context).textTheme.bodyText2!.color,
              fontSize: 15.0));
    }
    return Text(parent.song!.title.replaceAll('_', ' ').toUpperCase(),
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
        textAlign: TextAlign.center,
        style: TextStyle(
            color: Theme.of(context).textTheme.bodyText2!.color,
            fontSize: parent.song!.artist == '<unknown>' ? 12.0 : 13.0,
            letterSpacing: 6.0,
            fontWeight: parent._orientation == Orientation.portrait
                ? FontWeight.bold
                : FontWeight.w800));
  });
}

/// Renders current song artist
Widget _artist(_PlayerState parent) {
  return Builder(builder: (BuildContext context) {
    if (_bad.contains(parent._queueComplete) ||
        parent.song!.artist == '<unknown>') return const SizedBox.shrink();

    return Text(parent.song!.artist!.toUpperCase(),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: TextStyle(
            color: Theme.of(context).textTheme.bodyText2!.color,
            fontSize: 9.0,
            height: 2.0,
            letterSpacing: 6.0,
            fontWeight: parent._orientation == Orientation.portrait
                ? FontWeight.normal
                : FontWeight.w500));
  });
}

/// Renders main player control buttons
Row _mainControl(_PlayerState parent) {
  return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        IconButton(
            onPressed: () => parent.onChange(parent.index - 1),
            tooltip: 'Previous',
            icon: const Icon(Icons.skip_previous, size: 30.0)),
        _play(parent, 3.0, 30.0, parent._changeState),
        IconButton(
            onPressed: () => parent.onChange(parent.index + 1),
            tooltip: 'Next',
            icon: const Icon(Icons.skip_next, size: 30.0))
      ]);
}

/// Renders minor player control buttons
Widget _minorControl(_PlayerState parent) {
  return Builder(builder: (BuildContext context) {
    return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Row>[
          Row(children: <GestureDetector>[
            /*Tooltip(
                message: 'Select start',
                child: InkWell(
                    onTap: () {},
                    child: const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 20.0, vertical: 16.0),
                        child: Text('A',
                            style: TextStyle(
                                fontSize: 15.0,
                                fontWeight: FontWeight.bold))))),
            Tooltip(
                message: 'Select end',
                child: InkWell(
                    onTap: () {},
                    child: const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 20.0, vertical: 16.0),
                        child: Text('B',
                            style: TextStyle(
                                fontSize: 15.0,
                                fontWeight: FontWeight.bold))))),*/
            GestureDetector(
                onDoubleTap: () {
                  parent
                    ..onSet(context as StatelessElement)
                    ..onSet(context);
                },
                child: IconButton(
                    onPressed: () => parent.onSet(context as StatelessElement),
                    tooltip: 'Set (one, all, or random songs)',
                    icon: Icon(_status(parent._set), size: 20.0)))
          ]),
          Row(children: <IconButton>[
            IconButton(
                onPressed: () => parent.onMode(context as StatelessElement),
                tooltip: 'Mode (once or in a loop)',
                icon: Icon(
                    parent._mode == 'loop' ? Icons.repeat : Icons.trending_flat,
                    size: 20.0))
          ])
        ]);
  });
}

/// Picks appropriate [_set] icon
IconData _status(String aset) {
  switch (aset) {
    case 'all':
      return Icons.album;
    case '1':
      return Icons.music_note;
    default:
      return Icons.shuffle;
  }
}

String _timeInfo(int aqueueComplete, Duration time) {
  return _bad.contains(aqueueComplete)
      ? '0:00'
      : '${time.inMinutes}:${zero(time.inSeconds % 60)}';
}

/// Renders current folder's ancestors
Tooltip _navigation(_PlayerState parent) {
  final List<Widget> row = [];

  final String sourceRoot = parent.source.root;
  String linkPath = parent.chosenFolder;
  if (linkPath == sourceRoot) linkPath += '/${parent.source.name} home';
  final Iterable<int> relatives = parent.getRelatives(sourceRoot, linkPath);
  int j = 0;
  final int length = relatives.length;
  String linkTitle;
  int start = 0;
  while (j < length) {
    start = j - 1 < 0 ? sourceRoot.length : relatives.elementAt(j - 1);
    linkTitle = linkPath.substring(start + 1, relatives.elementAt(j));
    if (j + 1 == length) {
      row.add(InkWell(
          onTap: parent._pickFolder,
          child: Text(linkTitle,
              style: TextStyle(color: Theme.of(parent.context).primaryColor))));
    } else {
      row
        ..add(InkWell(
            onTap: () =>
                parent.onFolder(linkPath.substring(0, relatives.elementAt(j))),
            child: Text(linkTitle)))
        ..add(Text('>', style: TextStyle(color: unfocusedColor)));
    }
    j++;
  }
  return Tooltip(
      message: 'Change folder',
      child: Wrap(spacing: 8.0, runSpacing: 6.0, children: row));
}

/// Renders queue list
Widget _songPicker(parent) {
  if (parent.source.id == -1)
    return const Center(child: Text('Not yet supported!'));

  late List<SongModel> songList;
  if (parent.chosenFolder != parent.folder) {
    if (parent._tempQueueComplete == 0)
      return Center(
          child: Text('Loading...', style: TextStyle(color: unfocusedColor)));
    if (parent._tempQueueComplete == -1 && parent._tempQueue.isEmpty)
      return Center(
          child: Text('No songs in folder',
              style: TextStyle(color: unfocusedColor)));
    songList = parent._tempQueue;
  } else {
    if (parent._queueComplete == 0)
      return Center(
          child: Text('No songs in folder',
              style: TextStyle(color: unfocusedColor)));
    if (parent._queueComplete == -2)
      return const Center(child: Text('Unable to retrieve songs!'));
    songList = parent.queue;
  }
  return ListView.builder(
      key: PageStorageKey<int>(songList.hashCode),
      itemCount: songList.length,
      itemBuilder: (BuildContext context, int i) {
        final SongModel asong = songList[i];
        return ListTile(
            selected: parent.song == asong,
            onTap: () {
              if (parent.chosenFolder != parent.folder) {
                parent
                  ..onFolder(parent.chosenFolder)
                  ..setState(() => parent.index = parent.queue.indexOf(asong))
                  ..onPlay()
                  .._returnToPlayer();
              } else {
                if (parent.index == i) {
                  parent._changeState();
                } else {
                  parent
                    ..onStop()
                    ..setState(() => parent.index = i)
                    ..onPlay();
                }
              }
            },
            leading: SizedBox(
                height: 35.0,
                child: AspectRatio(
                    aspectRatio: 8 / 7, child: _listCover(parent, asong))),
            title: Text(asong.title.replaceAll('_', ' '),
                overflow: TextOverflow.ellipsis, maxLines: 1),
            subtitle: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Expanded(
                      child: Text(
                          asong.artist == '<unknown>' ? '' : asong.artist!,
                          style: const TextStyle(fontSize: 11.0),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1)),
                  Text(_timeInfo(
                      parent.chosenFolder != parent.folder
                          ? parent._tempQueueComplete
                          : parent._queueComplete,
                      Duration(milliseconds: asong.duration!)))
                ]),
            trailing: Icon(
                (parent.song == asong && parent._state == PlayerState.playing)
                    ? Icons.pause
                    : Icons.play_arrow,
                size: 30.0));
      });
}

/// Renders album artworks for queue list
Widget _listCover(_PlayerState parent, SongModel asong) {
  final Image? cover = parent._getCover(asong);
  if (cover != null) {
    return Material(
        clipBehavior: Clip.antiAlias,
        shape: parent._orientation == Orientation.portrait
            ? const _CubistShapeA()
            : const _CubistShapeC(),
        child: cover);
  }
  return const Icon(Icons.music_note);
}

/// List links in app info dialog
Wrap _appInfoLinks(_PlayerState parent) {
  TextButton _wrapTile(
      {required VoidCallback onPressed,
      required IconData icon,
      required String label}) {
    return TextButton.icon(
        icon: Icon(icon),
        label: Text(label),
        onPressed: onPressed,
        style: TextButton.styleFrom(
            primary: Colors.black,
            textStyle: const TextStyle(fontSize: 18.0),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap));
  }

  return Wrap(direction: Axis.vertical, runSpacing: 10.0, children: <
      TextButton>[
    _wrapTile(
        onPressed: () => showMarkdownPage(
            context: parent.context,
            applicationName: 'Changelog',
            selectable: true,
            filename: 'CHANGELOG.md'),
        icon: Icons.rule,
        label: 'Changelog'),
    _wrapTile(
        onPressed: () => launchUrl(
            Uri.parse('https://github.com/dvorapa/stepslow/issues/new/choose')),
        icon: Icons.report_outlined,
        label: 'Report issue'),
    _wrapTile(
        onPressed: () => showDialog(
            context: parent.context,
            builder: (BuildContext context) {
              return SingleChoiceDialog<String>(
                  isDividerEnabled: true,
                  items: const <String>['Paypal', 'Revolut'],
                  onSelected: (String method) => launchUrl(
                      Uri.parse('https://${method.toLowerCase()}.me/dvorapa')),
                  itemBuilder: (String method) {
                    return _textButtonLink(
                        icon: Icon(method == 'Paypal'
                            ? CupertinoIcons.money_pound_circle
                            : CupertinoIcons.bitcoin_circle),
                        label: Text(method));
                  });
            }),
        icon: Icons.favorite_outline,
        label: 'Sponsor'),
    _wrapTile(
        onPressed: () => launchUrl(Uri.parse('https://www.dvorapa.cz#kontakt')),
        icon: Icons.alternate_email,
        label: 'Contact'),
    _wrapTile(
        onPressed: () => showLicensePage(
            context: parent.context,
            applicationName: 'GNU General Public License v3.0'),
        icon: Icons.description_outlined,
        label: 'Licenses'),
    _wrapTile(
        onPressed: () =>
            launchUrl(Uri.parse('https://github.com/dvorapa/stepslow')),
        icon: Icons.code,
        label: 'Source code')
  ]);
}

/// List special features
Wrap _specialFeaturesList(parent) {
  FractionallySizedBox _cardRow({required List<Widget> children}) {
    return FractionallySizedBox(
        widthFactor: parent._orientation == Orientation.portrait ? 1.0 : .5,
        child: Padding(
            padding: const EdgeInsets.all(1.0),
            child: Card(
                elevation: 2.0,
                shape: const _CubistShapeF(),
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: children))));
  }

  return Wrap(children: <FractionallySizedBox>[
    _cardRow(children: <Widget>[const Text('Speed'), _ratePicker(parent)]),
    _cardRow(children: <Widget>[const Text('Intro'), _preludePicker(parent)]),
    _cardRow(
        children: <Widget>[const Text('Fade at'), _fadePositionPicker(parent)])
  ]);
}

/// Cubist shape for player slider.
class CubistWave extends CustomPainter {
  /// Player slider constructor
  CubistWave(this.title, this.duration, this.position, this.volume, this.color,
      this.afadePosition);

  /// Song title to parse
  String title;

  /// Song duration
  Duration duration;

  /// Current playback position
  Duration position;

  /// Playback volume to adjust duration
  int volume;

  /// Rendering color
  Color color;

  /// Position to switch songs
  Duration afadePosition;

  @override
  void paint(Canvas canvas, Size size) {
    final Map<int, double> waveList = wave(title).asMap();
    final int len = waveList.length - 1;
    if (duration == _emptyDuration) {
      duration = _defaultDuration;
    } else if (duration.inSeconds == 0) {
      duration = const Duration(seconds: 1);
    }

    final Path songPath = Path()..moveTo(0, size.height);
    waveList.forEach((int index, double value) {
      songPath.lineTo((size.width * index) / len,
          size.height - _heightFactor(size.height, volume, value));
    });
    songPath
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(songPath, Paint()..color = color.withOpacity(.7));

    final Path indicatorPath = Path();
    final double percentage = position.inSeconds / duration.inSeconds;
    final double pos = len * percentage;
    final int ceil = pos.ceil();
    indicatorPath.moveTo(0, size.height);
    waveList.forEach((int index, double value) {
      if (index < ceil) {
        indicatorPath.lineTo((size.width * index) / len,
            size.height - _heightFactor(size.height, volume, value));
      } else if (index == ceil) {
        final double previous = index == 0 ? size.height : waveList[index - 1]!;
        final double diff = value - previous;
        final double advance = 1 - (ceil - pos);
        indicatorPath.lineTo(
            size.width * percentage,
            size.height -
                _heightFactor(
                    size.height, volume, previous + (diff * advance)));
      }
    });
    indicatorPath
      ..lineTo(size.width * percentage, size.height)
      ..close();
    canvas.drawPath(indicatorPath, Paint()..color = color);

    if (afadePosition != _emptyDuration && afadePosition < duration) {
      final Path fadePath = Path();
      final double fadePercentage =
          afadePosition.inSeconds / duration.inSeconds;
      final double fade = len * fadePercentage;
      final int floor = fade.floor();
      fadePath.moveTo(size.width * fadePercentage, size.height);
      waveList.forEach((int index, double value) {
        if (index == floor) {
          final double next = index == (waveList.length - 1)
              ? size.height
              : waveList[index + 1]!;
          final double diff = next - value;
          final double advance = 1 - (fade - floor);
          fadePath.lineTo(
              size.width * fadePercentage,
              size.height -
                  _heightFactor(size.height, volume, next - (diff * advance)));
        } else if (index > floor) {
          fadePath.lineTo((size.width * index) / len,
              size.height - _heightFactor(size.height, volume, value));
        }
      });
      fadePath
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawPath(fadePath, Paint()..color = redColor.withOpacity(.7));
    }
  }

  @override
  bool shouldRepaint(CubistWave oldDelegate) => true;
}

/// Removes weird values from list using double standard deviation
Iterable<double> reduceList(Iterable<int> listToReduce) {
  double average =
      listToReduce.reduce((int val, int el) => val + el).toDouble();
  average = average / listToReduce.length;
  final Iterable<num> deviations =
      listToReduce.map((int el) => pow(el - average, 2));
  num deviationSum = deviations.reduce((num val, num el) => val + el);
  double stdev = sqrt(deviationSum / listToReduce.length);
  double lowerLimit = average - 2 * stdev;
  double upperLimit = average + 2 * stdev;
  return listToReduce
      .where((int el) => el >= lowerLimit && el <= upperLimit)
      .map((int el) => el.toDouble());
}

/// Generates wave data for slider
List<double> wave(String songTitle) {
  List<double> codes = reduceList(songTitle.toLowerCase().codeUnits)
      .where((double el) => el >= 48.0)
      .toList();

  final double minCode = codes.reduce(min);
  final double maxCode = codes.reduce(max);

  codes.asMap().forEach((int index, double value) {
    value = value - minCode;
    final double fraction = (100.0 / (maxCode - minCode)) * value;
    codes[index] = fraction.roundToDouble();
  });

  final int codesCount = codes.length;
  if (codesCount > 10)
    codes = codes.sublist(0, 5) + codes.sublist(codesCount - 5);

  return codes.toList();
}

/// Cubist shape for portrait album artworks.
/// ------
/// \    /
/// /    \
/// ------
class _CubistShapeA extends ShapeBorder {
  const _CubistShapeA();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..moveTo(rect.left, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right - rect.width / 20, rect.top + rect.height / 2)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left + rect.width / 20, rect.top + rect.height / 2)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// Cubist shape for portrait floating buttons.
///   ----
///  /  /
/// ----
class _CubistShapeB extends ShapeBorder {
  const _CubistShapeB();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..moveTo(rect.left + rect.width / 5, rect.top + rect.height / 5)
      ..lineTo(rect.right - rect.width / 10, rect.top + rect.height / 10)
      ..lineTo(rect.right - rect.width / 5, rect.bottom - rect.height / 5)
      ..lineTo(rect.left + rect.width / 10, rect.bottom - rect.height / 10)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// Cubist shape for landscape album artworks.
///  ______
/// /      \
/// \       \
///  \______/
class _CubistShapeC extends ShapeBorder {
  const _CubistShapeC();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..moveTo(rect.left + rect.width / 4, rect.top)
      ..lineTo(rect.right - rect.width / 2, rect.top)
      ..lineTo(rect.right - rect.width / 8, rect.top + rect.height / 8)
      ..lineTo(rect.right, rect.top + rect.height / 2)
      ..lineTo(rect.right, rect.bottom - rect.height / 4)
      ..lineTo(rect.right - rect.width / 4, rect.bottom)
      ..lineTo(rect.left + rect.width / 2, rect.bottom)
      ..lineTo(rect.left + rect.width / 8, rect.bottom - rect.height / 8)
      ..lineTo(rect.left, rect.bottom - rect.height / 2)
      ..lineTo(rect.left, rect.top + rect.height / 4)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// Cubist shape for landscape floating buttons.
/// ____
/// \  /
///  \/
class _CubistShapeD extends ShapeBorder {
  const _CubistShapeD();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..moveTo(rect.left - rect.width / 20, rect.top + rect.height / 6)
      ..lineTo(rect.right + rect.width / 20, rect.top + rect.height / 6)
      ..lineTo(rect.left + rect.width / 2, rect.bottom + rect.height / 20)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// Cubist shape for features page.
///  -----
/// /    |
/// |____|
class _CubistShapeE extends ShapeBorder {
  const _CubistShapeE();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..moveTo(rect.left + 2 * rect.width / 5, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.top + rect.height / 10)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}

/// Cubist shape for features page cards.
/// --v--
/// \   /
/// /   \
/// --^--
class _CubistShapeF extends ShapeBorder {
  const _CubistShapeF();

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..moveTo(rect.left, rect.top)
      ..lineTo(rect.left + 4 * rect.width / 10, rect.top)
      ..lineTo(rect.left + rect.width / 2, rect.top + rect.height / 10)
      ..lineTo(rect.left + 6 * rect.width / 10, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right - rect.width / 20, rect.top + rect.height / 2)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.right - 4 * rect.width / 10, rect.bottom)
      ..lineTo(rect.right - rect.width / 2, rect.bottom - rect.height / 10)
      ..lineTo(rect.right - 6 * rect.width / 10, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left + rect.width / 20, rect.top + rect.height / 2)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}
