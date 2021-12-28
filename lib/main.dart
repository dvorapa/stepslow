import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:flutter_ffmpeg/flutter_ffmpeg.dart';
import 'package:wakelock/wakelock.dart';
import 'package:easy_dialogs/easy_dialogs.dart';
import 'package:typicons_flutter/typicons_flutter.dart';
import 'package:yaml/yaml.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:about/about.dart' show showMarkdownPage;
import 'pubspec.dart';

/// Theme main color
final Color interactiveColor = Colors.orange[300]!; // #FFB74D #FFA726

/// Light theme color
final Color backgroundColor = Colors.white;

/// YouTube components color
final Color youtubeColor = Colors.red; // #E4273A

/// Text main color
final Color unfocusedColor = Colors.grey[400]!;

/// Dark theme color
final Color blackColor = Colors.black;

/// Duration initializer
Duration _emptyDuration = Duration.zero;

/// Default duration for empty queue
Duration _defaultDuration = const Duration(seconds: 5);

/// Default duration for animations
Duration _animationDuration = const Duration(milliseconds: 300);

/// Default duration for animations
final Curve _animationCurve = Curves.ease;

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
bool _debug = true;

/// Pads seconds
String zero(int n) {
  if (n >= 10) return '$n';
  return '0$n';
}

/// Calculates height factor for wave
double _heightFactor(double _height, double _rate, double _value) =>
    (_height / 400.0) * (3.0 * _rate / 2.0 + _value);

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
    if (_sources.any((Source _source) => _source.root == path)) return '';

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
        title: 'Stepslow music player',
        theme: ThemeData(
            primaryColor: interactiveColor,
            appBarTheme: AppBarTheme(
                color: Colors.transparent,
                elevation: .0,
                iconTheme: IconThemeData(color: unfocusedColor),
                titleTextStyle: TextStyle(color: blackColor),
                toolbarTextStyle: TextStyle(color: blackColor)),
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
  _PlayerState createState() => _PlayerState();
}

/// State handler.
class _PlayerState extends State<Player> with WidgetsBindingObserver {
  /// Audio player entity
  final AudioPlayer audioPlayer = AudioPlayer();

  /// Android intent channel entity
  final MethodChannel bridge =
      const MethodChannel('cz.dvorapa.stepslow/sharedPath');

  /// Current playback state
  PlayerState _state = PlayerState.STOPPED;

  /// Current playback rate
  double _rate = 100.0;

  /// Previous playback rate
  double _previousRate = 100.0;

  /// Current playback position
  Duration _position = _emptyDuration;

  /// Position to switch songs
  Duration _fadePosition = _emptyDuration;

  /// Playback song from last run
  String? lastSongPath;

  /// Current playback mode
  String _mode = 'loop';

  /// Current playback set
  String _set = 'random';

  late Orientation _orientation;

  /// False if [_rate] picker should be hidden
  bool _showRatePicker = false;

  /// False if [_showRatePicker] was false at last redraw
  bool _previousRatePicker = false;

  /// Timer to release [_showRatePicker]
  Timer? _rateCoverTimer;

  /// Text to speech for prelude
  final FlutterTts _tts = FlutterTts();

  /// Prelude length before playback
  int _introLength = 0;

  /// Random generator to shuffle queue after startup
  final Random random = Random();

  /// History of page transitions
  List<int> pageHistory = [2];

  /// [PageView] controller
  final PageController _controller = PageController(initialPage: 2);

  /// Current playback source
  Source source = _sources[0];

  /// Current playback folder
  String folder = '/storage/emulated/0/Music';

  /// Chosen playback folder
  String chosenFolder = '/storage/emulated/0/Music';

  /// Current playback song
  SongModel? song;

  /// Previous playback song
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

  /// FFmpeg entity to query album artworks
  final FlutterFFmpeg _flutterFFmpeg = FlutterFFmpeg();

  /// FFmpeg config
  final FlutterFFmpegConfig _flutterFFmpegConfig = FlutterFFmpegConfig();

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

  /// Initializes [song] playback
  void onPlay({bool quiet = false}) {
    if (_state == PlayerState.PAUSED || quiet) {
      audioPlayer.resume();
    } else {
      setState(() => song = queue[index]);
      final String _songPath = song!.data;
      if (_introLength != 0) {
        onStop(quiet: true);
        audioPlayer.setUrl(_songPath, isLocal: true);
      }
      final List<String> _range = [
        for (int i = _introLength; i > 0; i--) i.toString()
      ];
      _ttsTimer?.cancel();
      _ttsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_range.isEmpty) {
          audioPlayer.play(_songPath, isLocal: true);
          _ttsTimer?.cancel();
        } else {
          _tts.speak(_range.removeAt(0));
        }
      });
      setState(() => lastSongPath = _songPath);
      _setValue('lastSongPath', _songPath);
    }
    onRate(_rate);
    if (!quiet) setState(() => _state = PlayerState.PLAYING);
    Wakelock.enable();
  }

  /// Changes [song] according to given [_index]
  void onChange(int _index) {
    final int available = queue.length;
    setState(() {
      if (_index < 0) {
        index = _index + available;
        if (_set == 'random' && queue.length > 2) {
          queue.shuffle();
          while (song == queue[index]) queue.shuffle();
        }
      } else if (_index >= available) {
        index = _index - available;
        if (_set == 'random' && queue.length > 2) {
          queue.shuffle();
          while (song == queue[index]) queue.shuffle();
        }
      } else {
        index = _index;
      }
    });
    if (_state == PlayerState.PLAYING) {
      onPlay();
    } else {
      onStop();
      setState(() {
        song = queue.isNotEmpty ? queue[index] : null;
        if (song != null) duration = Duration(milliseconds: song!.duration!);
      });
      if (song != null) {
        final String _songPath = song!.data;
        setState(() => lastSongPath = _songPath);
        _setValue('lastSongPath', _songPath);
      }
    }
  }

  /// Pauses [song] playback
  void onPause({bool quiet = false}) {
    _ttsTimer?.cancel();
    if (_ttsTimer != null && !_ttsTimer!.isActive) {
      audioPlayer.pause();
      if (!quiet) setState(() => _state = PlayerState.PAUSED);
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
      _state = PlayerState.STOPPED;
    });
    Wakelock.disable();
  }

  /// Changes [folder] according to given
  void onFolder(String _folder) {
    if (folder != _folder) {
      queue.clear();
      setState(() {
        index = 0;
        _queueComplete = 0;
      });
      if (!_bad.contains(_songsComplete)) {
        for (final SongModel _song in _songs) {
          if (File(_song.data).parent.path == _folder) {
            if (_set != 'random' || [0, 1].contains(_queueComplete)) {
              queue.add(_song);
            } else {
              queue.insert(1 + random.nextInt(_queueComplete), _song);
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
        folder = _folder;
        chosenFolder = _folder;
        _introLength = 0;
      });
    }
  }

  /// Creates temporary queue list
  void _getTempQueue(String _tempFolder) {
    if (chosenFolder != _tempFolder) {
      setState(() {
        chosenFolder = _tempFolder;
        _tempQueueComplete = 0;
      });
      _tempQueue.clear();
      if (!_bad.contains(_songsComplete)) {
        for (final SongModel _song in _songs) {
          if (File(_song.data).parent.path == _tempFolder) {
            _tempQueue.add(_song);
            setState(() => ++_tempQueueComplete);
          }
        }
      }
      setState(() => _tempQueueComplete = -1);
    }
  }

  /// Initializes shared or saved [song] playback
  Future<void> loadSpecificSong() async {
    final String? _sharedPath = await bridge.invokeMethod('openSharedPath');
    final String? _path = _sharedPath ?? lastSongPath;
    if (_path != null && _path != song?.data) {
      final String _newFolder = File(_path).parent.path;
      final Source _newSource =
          _sources.firstWhereOrNull(_newFolder.startsWith) ?? source;
      if (source != _newSource) setState(() => source = _newSource);
      onFolder(_newFolder);
      final int _index =
          queue.indexWhere((SongModel _song) => _song.data == _path);
      onChange(_index);
      if (_sharedPath != null) onPlay();
    }
  }

  /// Changes playback [_mode] and informs user using given [context]
  void onMode(StatelessElement context) {
    setState(() => _mode = _mode == 'loop' ? 'once' : 'loop');
    _setValue('_mode', _mode);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Theme.of(context).colorScheme.secondary,
        elevation: .0,
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
        elevation: .0,
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
    if (_state == PlayerState.PLAYING) onPause(quiet: true);
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
    if (_state == PlayerState.PLAYING) onPlay(quiet: true);
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
    double newPosition = .0;

    if (position.dx <= 0) {
      newPosition = .0;
    } else if (position.dx >= width) {
      newPosition = width;
    } else {
      newPosition = position.dx;
    }

    setState(() => _position = duration * (newPosition / width));

    audioPlayer.seek(_position * (_rate / 100.0));
  }

  /// Starts to listen [_rate] drag actions
  void onRateDragStart(BuildContext context, DragStartDetails details) {
    final RenderBox slider = context.findRenderObject() as RenderBox;
    final Offset rate = slider.globalToLocal(details.globalPosition);
    if (_state == PlayerState.PLAYING) onPause(quiet: true);
    updateRate(rate, slider.constraints.biggest.height);
  }

  /// Listens [_rate] drag actions
  void onRateDragUpdate(BuildContext context, DragUpdateDetails details) {
    final RenderBox slider = context.findRenderObject() as RenderBox;
    final Offset rate = slider.globalToLocal(details.globalPosition);
    updateRate(rate, slider.constraints.biggest.height);
  }

  /// Ends to listen [_rate] drag actions
  void onRateDragEnd(BuildContext context, DragEndDetails details) {
    if (_state == PlayerState.PLAYING) onPlay(quiet: true);
  }

  /// Changes playback [_rate] according to given offset
  void updateRate(Offset rate, double height) {
    double newRate = 100.0;

    if (rate.dy <= .0) {
      newRate = .0;
    } else if (rate.dy >= height) {
      newRate = height;
    } else {
      newRate = rate.dy;
    }

    newRate = 200.0 * (1 - (newRate / height));
    newRate = newRate - newRate % 5;
    if (newRate < 5) newRate = 5;
    onRate(newRate);
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
  void _changeState() => _state == PlayerState.PLAYING ? onPause() : onPlay();

  /// Shows dialog to pick [source]
  void _pickSource() {
    showDialog(
        context: context,
        builder: (BuildContext context) {
          return SingleChoiceDialog<Source>(
              isDividerEnabled: true,
              items: _sources,
              onSelected: (Source _source) {
                setState(() => source = _source);
                onFolder(_source.root);
              },
              itemBuilder: (Source _source) {
                final Text _sourceText = source == _source
                    ? Text(_source.name,
                        style: TextStyle(color: Theme.of(context).primaryColor))
                    : Text(_source.name);
                switch (_source.id) {
                  case -1:
                    return Wrap(
                        spacing: 12.0,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        children: <Widget>[
                          Icon(Typicons.social_youtube,
                              color: source == _source
                                  ? Theme.of(context).primaryColor
                                  : youtubeColor),
                          _sourceText
                        ]);
                  case 0:
                    return Wrap(
                        spacing: 12.0,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        children: <Widget>[
                          Icon(Icons.phone_iphone,
                              color: source == _source
                                  ? Theme.of(context).primaryColor
                                  : Theme.of(context)
                                      .textTheme
                                      .bodyText2!
                                      .color!
                                      .withOpacity(.55)),
                          _sourceText
                        ]);
                  default:
                    return Wrap(
                        spacing: 12.0,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        children: <Widget>[
                          Icon(Icons.sd_card,
                              color: source == _source
                                  ? Theme.of(context).primaryColor
                                  : Theme.of(context)
                                      .textTheme
                                      .bodyText2!
                                      .color!
                                      .withOpacity(.55)),
                          _sourceText
                        ]);
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
    if (1.9 < _controller.page! && _controller.page! < 2.1) {
      setState(() => pageHistory = [2]);
      return true;
    }
    _controller.animateToPage(pageHistory[0],
        duration: _animationDuration, curve: _animationCurve);
    setState(() => pageHistory = [2]);
    return false;
  }

  /// Get cached or preferred value
  void _getSavedValues() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      lastSongPath = prefs.getString('lastSongPath');
      _mode = prefs.getString('_mode') ?? 'loop';
      _set = prefs.getString('_set') ?? 'random';
    });
    await prefs.setString('_mode', _mode);
    await prefs.setString('_set', _set);
  }

  /// Save cached or preferred value
  Future<void> _setValue(String variable, dynamic value) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    if (value is String) await prefs.setString(variable, value);
    if (value is double) await prefs.setDouble(variable, value);
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
    for (final SongModel _song in _songs) {
      final String _songPath = _song.data;
      final String _coversPath =
          (_sources.firstWhereOrNull(_songPath.startsWith)?.coversPath ??
              _sources[0].coversPath)!;
      final String _coverPath = '$_coversPath/${_songPath.hashCode}.jpg';
      int _status = 0;
      if (!File(_coverPath).existsSync()) {
        final int _height =
            (MediaQuery.of(context).size.shortestSide * 7 / 10).ceil();
        _status = await _flutterFFmpeg
            .execute(
                '-i "$_songPath" -vf scale="-2:\'min($_height,ih)\'":flags=lanczos -an "$_coverPath"')
            .catchError((error) {
          print(error.stackTrace);
          setState(() => _coversComplete = -2);
          return 1;
        });
      }
      _coversMap[_songPath] = _status;
      _coversYaml.add('"$_songPath": $_status');
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
  Widget? _getCover(SongModel _song) {
    if (_coversComplete == -1) {
      final String _songPath = _song.data;
      if (_coversMap.containsKey(_songPath)) {
        if (_coversMap[_songPath] == 0) {
          final String _coversPath =
              (_sources.firstWhereOrNull(_songPath.startsWith)?.coversPath ??
                  _sources[0].coversPath)!;
          final File _coverFile =
              File('$_coversPath/${_songPath.hashCode}.jpg');
          if (_coverFile.existsSync()) {
            return Image.file(_coverFile, fit: BoxFit.cover);
          } else {
            _fixCover(_song);
          }
        }
      } else {
        _fixCoversMap();
      }
    }
    return null;
  }

  /// Fixes album artwork in cache
  Future<void> _fixCover(SongModel _song) async {
    if (_coversComplete == -1) {
      setState(() => _coversComplete = 0);
      final String _songPath = _song.data;
      final String _coversPath =
          (_sources.firstWhereOrNull(_songPath.startsWith)?.coversPath ??
              _sources[0].coversPath)!;
      final String _coverPath = '$_coversPath/${_songPath.hashCode}.jpg';
      int _status = 0;
      final int _height =
          (MediaQuery.of(context).size.shortestSide * 7 / 10).ceil();
      _status = await _flutterFFmpeg
          .execute(
              '-i "$_songPath" -vf scale="-2:\'min($_height,ih)\'":flags=lanczos -an "$_coverPath"')
          .catchError((error) {
        print(error.stackTrace);
        setState(() => _coversComplete = -2);
        return 1;
      });
      _coversMap[_songPath] = _status;
      setState(() => ++_coversComplete);
      _coversYaml = ['---'];
      _coversMap.forEach((String _coverSong, int _coverStatus) =>
          _coversYaml.add('"$_coverSong": $_coverStatus'));
      await _cacheCoversMap();
    }
  }

  /// Gets relative urls for [fillBrowse]
  Iterable<int> getRelatives(String root, String path) {
    final int _rootLength = root.length;
    String relative = path.substring(_rootLength);
    if (relative.startsWith('/')) relative = '${relative.substring(1)}/';
    return '/'.allMatches(relative).map((Match m) => _rootLength + m.end);
  }

  /// Fills [browse] stack with given [_path]
  void fillBrowse(
      String _path,
      String _root,
      SplayTreeMap<Entry, SplayTreeMap> browse,
      int value,
      ValueChanged<int> valueChanged,
      String type) {
    final Iterable<int> relatives = getRelatives(_root, _path);
    int j = 0;
    String relativeString;
    num length = type == 'song' ? relatives.length - 1 : relatives.length;
    if (length == 0) length = .5;
    while (j < length) {
      relativeString =
          length == .5 ? _root : _path.substring(0, relatives.elementAt(j));
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
    _flutterFFmpegConfig.disableRedirection();

    _getSavedValues();

    audioPlayer.onDurationChanged.listen((Duration d) {
      setState(() => duration = d * (100.0 / _rate));
    });
    audioPlayer.onAudioPositionChanged.listen((Duration p) {
      setState(() => _position = p * (100.0 / _rate));
      if (_fadePosition > _emptyDuration && _position > _fadePosition) {
        onPause(quiet: true);
        onChange(index + 1);
        onPlay();
      }
    });
    audioPlayer.onPlayerCompletion.listen((_) {
      setState(() => _position = duration);
      if (_mode == 'once' && (_set == '1' || index == queue.length - 1)) {
        onStop();
      } else if (_set == '1') {
        onPlay();
      } else {
        onChange(index + 1);
      }
    });
    audioPlayer.onPlayerError.listen((String error) {
      onStop();
      print(error);
    });

    _controller.addListener(() {
      final double _modulo = _controller.page! % 1;
      if (.9 < _modulo || _modulo < .1) {
        final int _page = _controller.page!.round();
        if (!pageHistory.contains(_page)) {
          pageHistory.add(_page);
          while (pageHistory.length > 2) pageHistory.removeAt(0);
        }
      }
    });

    super.initState();

    Permission.storage.request().then((PermissionStatus _status) {
      if (_status == PermissionStatus.permanentlyDenied) {
        openAppSettings();
      } else if (_status == PermissionStatus.denied) {
        SystemChannels.platform.invokeMethod('SystemNavigator.pop');
      }
      // Got permission (read user files and folders)
      checkoutSdCards().listen(_sources.add,
          onDone: () {
            // Got _sources
            Stream<List<SongModel>>.fromFuture(OnAudioQuery().querySongs())
                .expand((List<SongModel> _songs) => _songs)
                .listen((SongModel _song) {
              final String _songPath = _song.data;
              // queue
              if (File(_songPath).parent.path == folder) {
                if (_set != 'random' || [0, 1].contains(_queueComplete)) {
                  queue.add(_song);
                } else {
                  queue.insert(1 + random.nextInt(_queueComplete), _song);
                }
                setState(() => ++_queueComplete);
                if (_queueComplete == 1) {
                  audioPlayer.setUrl(_songPath, isLocal: true);
                  setState(() => song = queue[0]);
                }
              }

              if (_sources.any(_songPath.startsWith)) {
                // _songs
                _songs.add(_song);
                setState(() => ++_songsComplete);

                // browse
                final Source _source =
                    _sources.firstWhere(_songPath.startsWith);
                fillBrowse(
                    _songPath,
                    _source.root,
                    _source.browse,
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
                    (Source _source) => _source.browseFoldersComplete == -1))
                  _browseComplete = -1;
                _browseSongsComplete = _browseSongsComplete > 0 ? -1 : 0;
              });
              if (_songsComplete == -1 &&
                  _coversFile != null &&
                  !_sources.any((Source _source) => _source.coversPath == null))
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

            for (final Source _source in _sources) {
              getFolders(_source.root).listen((String _folderPath) {
                fillBrowse(
                    _folderPath,
                    _source.root,
                    _source.browse,
                    _source.browseFoldersComplete,
                    (value) => _source.browseFoldersComplete = value,
                    'folder');
              }, onDone: () {
                fillBrowse(
                    _source.root,
                    _source.root,
                    _source.browse,
                    _source.browseFoldersComplete,
                    (value) => _source.browseFoldersComplete = value,
                    'folder');
                // Got folders
                setState(() {
                  _source.browseFoldersComplete = -1;
                  if ((_browseSongsComplete == -1) &&
                      _sources.every((Source _source) =>
                          _source.browseFoldersComplete == -1))
                    _browseComplete = -1;
                });
                loadSpecificSong();
                WidgetsBinding.instance!.addObserver(this);
              }, onError: (error) {
                setState(() {
                  _browseComplete = -2;
                  _source.browseFoldersComplete = -2;
                });
                print(error.stackTrace);
              });
            }

            getTemporaryDirectory().then((Directory _appCache) {
              final String _appCachePath = _appCache.path;
              for (final Source _source in _sources)
                _source.coversPath = _appCachePath;

              if (Platform.isAndroid) {
                Stream<List<Directory>?>.fromFuture(
                        getExternalCacheDirectories())
                    .expand((List<Directory>? _extCaches) => _extCaches!)
                    .listen((Directory _extCache) {
                  final String _extCachePath = _extCache.path;
                  if (!_extCachePath.startsWith(_sources[0])) {
                    _sources.firstWhere(_extCachePath.startsWith).coversPath =
                        _extCachePath;
                  } else if (_debug) {
                    _sources[0].coversPath = _extCachePath;
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
        .expand((List<InternetAddress> _addresses) => _addresses)
        .firstWhere(
            (InternetAddress _address) => _address.rawAddress.isNotEmpty)
        .then((_) => _sources.add(Source('', -1)),
            onError: (error) => print(error.stackTrace));*/
    // Got YouTube

    getApplicationSupportDirectory().then((Directory _appData) {
      _coversFile = File('${_appData.path}/covers.yaml');

      if (Platform.isAndroid && _debug) {
        late StreamSubscription<Directory> _extDataStream;
        _extDataStream =
            Stream<List<Directory>?>.fromFuture(getExternalStorageDirectories())
                .expand((List<Directory>? _extDatas) => _extDatas!)
                .listen((Directory _extData) {
          final String _extDataPath = _extData.path;
          if (_extDataPath.startsWith(_sources[0])) {
            _coversFile = File('$_extDataPath/covers.yaml');
            // Got _coversFile
            if (_songsComplete == -1 &&
                !_sources.any((Source _source) => _source.coversPath == null))
              _loadCoversMap();
            _extDataStream.cancel();
          }
        }, onError: (error) => print(error.stackTrace));
      } else {
        if (_songsComplete == -1 &&
            !_sources.any((Source _source) => _source.coversPath == null))
          _loadCoversMap();
      }
    }, onError: (error) => print(error.stackTrace));
  }

  @override
  void dispose() {
    audioPlayer.release();
    WidgetsBinding.instance!.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState _state) {
    if (_state == AppLifecycleState.resumed) loadSpecificSong();
  }

  @override
  Widget build(BuildContext context) {
    if (_previousRate != _rate) {
      _showRatePicker = true;
      _previousRate = _rate;
      _rateCoverTimer?.cancel();
      _rateCoverTimer = Timer(_defaultDuration, () {
        setState(() => _showRatePicker = false);
      });
    }
    if (_previousSong != song) {
      _showRatePicker = false;
      _previousSong = song;
      _rateCoverTimer?.cancel();
    }
    if (_previousRatePicker != _showRatePicker) {
      _rateCoverTimer?.cancel();
      _rateCoverTimer = Timer(_defaultDuration, () {
        setState(() => _showRatePicker = false);
      });
    }
    _previousRatePicker = _showRatePicker;
    _orientation = MediaQuery.of(context).orientation;
    return Material(
        child: PageView(
            controller: _controller,
            physics: const BouncingScrollPhysics(),
            children: <Widget>[
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
                              onTap: _pickSource, child: Text(source.name)))),
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
                                  if (_state == PlayerState.PLAYING)
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
                      actions: <Widget>[
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
                          children: <Widget>[
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
                                                        _rate,
                                                        wave(song?.title ?? 'zapaz')
                                                            .first),
                                                    child: Container(
                                                        alignment:
                                                            Alignment.center,
                                                        padding: const EdgeInsets
                                                                .symmetric(
                                                            horizontal: 12.0),
                                                        color: youtubeColor,
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
                                          16.0, 12.0, 16.0, .0),
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
                      : Column(children: <Widget>[
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
                                        heightFactor: _heightFactor(1, _rate,
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
                                                    _rate,
                                                    wave(song?.title ?? 'zapaz')
                                                        .first),
                                                child: Container(
                                                    alignment: Alignment.center,
                                                    padding: const EdgeInsets
                                                            .symmetric(
                                                        horizontal: 12.0),
                                                    color: youtubeColor,
                                                    child: Text(
                                                        '$_introLength s',
                                                        style: TextStyle(
                                                            color: Theme.of(
                                                                    context)
                                                                .scaffoldBackgroundColor))))),
                                    Expanded(child: _playerOblong(this)),
                                    FractionallySizedBox(
                                        heightFactor: _heightFactor(1, _rate,
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
                                            child: Text(_timeInfo(_queueComplete, _fadePosition == _emptyDuration ? duration : _fadePosition),
                                                style: TextStyle(
                                                    color: _fadePosition ==
                                                            _emptyDuration
                                                        ? Theme.of(context)
                                                            .scaffoldBackgroundColor
                                                        : youtubeColor,
                                                    fontWeight: _fadePosition ==
                                                            _emptyDuration
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
                      actions: <Widget>[
                        IconButton(
                            onPressed: () => showDialog(
                                context: context,
                                builder: (BuildContext context) {
                                  return AlertDialog(
                                      content: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            const Center(
                                                child: Text(Pubspec.name,
                                                    style: TextStyle(
                                                        fontSize: 32.0))),
                                            Center(
                                                child: Text(
                                                    '${Pubspec.description}\nversion ${Pubspec.version}, build ${Pubspec.versionBuild}\nby @dvorapa',
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                        color: unfocusedColor,
                                                        fontSize: 13.0))),
                                            InkWell(
                                                onTap: () => showMarkdownPage(
                                                    context: context,
                                                    applicationName:
                                                        'Changelog',
                                                    selectable: true,
                                                    filename: 'CHANGELOG.md'),
                                                child: Wrap(
                                                    spacing: 12.0,
                                                    crossAxisAlignment:
                                                        WrapCrossAlignment.end,
                                                    children: const <Widget>[
                                                      Icon(Icons.rule),
                                                      Text('Changelog',
                                                          style: TextStyle(
                                                              fontSize: 18.0))
                                                    ])),
                                            InkWell(
                                                onTap: () => launch(
                                                    'https://github.com/dvorapa/stepslow/issues/new/choose'),
                                                child: Wrap(
                                                    spacing: 12.0,
                                                    crossAxisAlignment:
                                                        WrapCrossAlignment.end,
                                                    children: const <Widget>[
                                                      Icon(Icons
                                                          .report_outlined),
                                                      Text('Report issue',
                                                          style: TextStyle(
                                                              fontSize: 18.0))
                                                    ])),
                                            InkWell(
                                                onTap: () => showDialog(
                                                    context: context,
                                                    builder:
                                                        (BuildContext context) {
                                                      return SingleChoiceDialog<
                                                              String>(
                                                          isDividerEnabled:
                                                              true,
                                                          items: const <String>[
                                                            'Paypal',
                                                            'Revolut'
                                                          ],
                                                          onSelected: (String
                                                                  _method) =>
                                                              launch(
                                                                  'https://${_method.toLowerCase()}.me/dvorapa'),
                                                          itemBuilder:
                                                              (String _method) {
                                                            return Wrap(
                                                                spacing: 12.0,
                                                                crossAxisAlignment:
                                                                    WrapCrossAlignment
                                                                        .end,
                                                                children: <
                                                                    Widget>[
                                                                  Icon(_method ==
                                                                          'Paypal'
                                                                      ? CupertinoIcons
                                                                          .money_pound_circle
                                                                      : CupertinoIcons
                                                                          .bitcoin_circle),
                                                                  Text(_method)
                                                                ]);
                                                          });
                                                    }),
                                                child: Wrap(
                                                    spacing: 12.0,
                                                    crossAxisAlignment:
                                                        WrapCrossAlignment.end,
                                                    children: const <Widget>[
                                                      Icon(Icons
                                                          .favorite_outline),
                                                      Text('Sponsor',
                                                          style: TextStyle(
                                                              fontSize: 18.0))
                                                    ])),
                                            InkWell(
                                                onTap: () => launch(
                                                    'https://www.dvorapa.cz#kontakt'),
                                                child: Wrap(
                                                    spacing: 12.0,
                                                    crossAxisAlignment:
                                                        WrapCrossAlignment.end,
                                                    children: const <Widget>[
                                                      Icon(Icons
                                                          .alternate_email),
                                                      Text('Contact',
                                                          style: TextStyle(
                                                              fontSize: 18.0))
                                                    ])),
                                            InkWell(
                                                onTap: () => showLicensePage(
                                                    context: context,
                                                    applicationName:
                                                        'GNU General Public License v3.0'),
                                                child: Wrap(
                                                    spacing: 12.0,
                                                    crossAxisAlignment:
                                                        WrapCrossAlignment.end,
                                                    children: const <Widget>[
                                                      Icon(Icons
                                                          .description_outlined),
                                                      Text('Licenses',
                                                          style: TextStyle(
                                                              fontSize: 18.0))
                                                    ])),
                                            InkWell(
                                                onTap: () => launch(
                                                    'https://github.com/dvorapa/stepslow'),
                                                child: Wrap(
                                                    spacing: 12.0,
                                                    crossAxisAlignment:
                                                        WrapCrossAlignment.end,
                                                    children: const <Widget>[
                                                      Icon(Icons.code),
                                                      Text('Source code',
                                                          style: TextStyle(
                                                              fontSize: 18.0))
                                                    ]))
                                          ]
                                              .map((Widget _widget) => Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(vertical: 5.0),
                                                  child: _widget))
                                              .toList()),
                                      actions: <Widget>[
                                        TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            child: const Text('Close',
                                                style:
                                                    TextStyle(fontSize: 16.0)))
                                      ],
                                      scrollable: true);
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
                            : const EdgeInsets.fromLTRB(40.0, .0, 20.0, 20.0),
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
                                child: GridView.count(
                                    crossAxisCount:
                                        _orientation == Orientation.portrait
                                            ? 1
                                            : 2,
                                    mainAxisSpacing: 2.5,
                                    crossAxisSpacing: 2.5,
                                    childAspectRatio: 2.69,
                                    padding: EdgeInsets.all(
                                        _orientation == Orientation.portrait ? 40.0 : 20.0),
                                    children: <Widget>[
                                      Card(
                                          elevation: 2.0,
                                          shape: const _CubistShapeF(),
                                          child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.spaceEvenly,
                                              children: <Widget>[
                                                const Text('Speed'),
                                                _ratePicker(this)
                                              ])),
                                      Card(
                                          elevation: 2.0,
                                          shape: const _CubistShapeF(),
                                          child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.spaceEvenly,
                                              children: <Widget>[
                                                const Text('Intro'),
                                                _preludePicker(this)
                                              ])),
                                      Card(
                                          elevation: 2.0,
                                          shape: const _CubistShapeF(),
                                          child: Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.spaceEvenly,
                                              children: <Widget>[
                                                const Text('Fade at'),
                                                _fadePositionPicker(this)
                                              ]))
                                    ]))))
                  ])))
        ]));
  }
}

/// Picks appropriate icon according to [sourceId] given
Widget _sourceButton(int sourceId, Color darkColor) {
  switch (sourceId) {
    case -1:
      return Icon(Typicons.social_youtube, color: youtubeColor);
    case 0:
      return Icon(Icons.phone_iphone, color: darkColor);
    default:
      return Icon(Icons.sd_card, color: darkColor);
  }
}

/// Renders folder list
Widget _folderPicker(_PlayerState parent) {
  if (parent.source.id == -1)
    return const Center(child: Text('Not yet supported!'));

  final int _browseComplete = parent._browseComplete;
  final SplayTreeMap<Entry, SplayTreeMap> browse = parent.source.browse;
  if (_browseComplete == 0) {
    return Center(
        child:
            Text('No folders found', style: TextStyle(color: unfocusedColor)));
  } else if (_browseComplete == -2) {
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
Widget _folderTile(parent, MapEntry<Entry, SplayTreeMap> entry) {
  final SplayTreeMap<Entry, SplayTreeMap> _children =
      entry.value as SplayTreeMap<Entry, SplayTreeMap>;
  final Entry _entry = entry.key;
  final String _entryPath = _entry.path;
  if (_children.isNotEmpty) {
    return ExpansionTile(
        /*key: PageStorageKey<MapEntry>(entry),*/
        key: UniqueKey(),
        initiallyExpanded: parent.chosenFolder.contains(_entryPath),
        onExpansionChanged: (_) => parent._getTempQueue(_entryPath),
        childrenPadding: const EdgeInsets.only(left: 16.0),
        title: Text(_entry.name,
            style: TextStyle(
                fontSize: 14.0,
                color: parent.folder == _entryPath
                    ? Theme.of(parent.context).primaryColor
                    : Theme.of(parent.context).textTheme.bodyText2!.color)),
        subtitle: Text(_entry.songs == 1 ? '1 song' : '${_entry.songs} songs',
            style: TextStyle(
                fontSize: 10.0,
                color: parent.folder == _entryPath
                    ? Theme.of(parent.context).primaryColor
                    : Theme.of(parent.context)
                        .textTheme
                        .bodyText2!
                        .color!
                        .withOpacity(.55))),
        children: _children.entries
            .map((MapEntry<Entry, SplayTreeMap> entry) =>
                _folderTile(parent, entry))
            .toList());
  }
  return ListTile(
      selected: parent.folder == _entryPath,
      onTap: () {
        parent
          .._getTempQueue(_entryPath)
          .._pickSong();
      },
      title: _entry.name.isEmpty
          ? Align(
              alignment: Alignment.centerLeft,
              child: Icon(Icons.home,
                  color: parent.folder == _entryPath
                      ? Theme.of(parent.context).primaryColor
                      : unfocusedColor))
          : Text(_entry.name, style: const TextStyle(fontSize: 14.0)),
      subtitle: Text(_entry.songs == 1 ? '1 song' : '${_entry.songs} songs',
          style: const TextStyle(fontSize: 10.0)));
}

/// Renders play/pause button
Widget _play(_PlayerState parent, double elevation, double iconSize,
    VoidCallback onPressed) {
  return Builder(builder: (BuildContext context) {
    final ShapeBorder _shape = parent._orientation == Orientation.portrait
        ? const _CubistShapeB()
        : const _CubistShapeD();
    if (parent._queueComplete == 0) {
      return FloatingActionButton(
          onPressed: () {},
          tooltip: 'Loading...',
          shape: _shape,
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
          shape: _shape,
          elevation: elevation,
          child: Icon(Icons.close, size: iconSize));
    }
    return FloatingActionButton(
        onPressed: onPressed,
        tooltip: parent._state == PlayerState.PLAYING ? 'Pause' : 'Play',
        shape: _shape,
        elevation: elevation,
        child: Icon(
            parent._state == PlayerState.PLAYING
                ? Icons.pause
                : Icons.play_arrow,
            size: iconSize));
  });
}

/// Handles squared player section
Widget _playerSquared(_PlayerState parent) {
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
              child: _rateCover(parent))));
}

/// Renders rate selector
Widget _ratePicker(parent) {
  return Builder(builder: (BuildContext context) {
    String _message = 'Set player speed';
    GestureTapCallback _onTap = () {};
    final TextStyle _textStyle = TextStyle(
        fontSize: 30, color: Theme.of(context).textTheme.bodyText2!.color);
    if (parent._rate != 100.0) {
      _message = 'Reset player speed';
      _onTap = () => parent.onRate(100.0);
    }
    return Center(
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      Tooltip(
          message: _message,
          child: InkWell(
              onTap: _onTap,
              child: Text('${parent._rate.toInt()}', style: _textStyle))),
      Column(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
        IconButton(
            onPressed: () => parent.onRate(parent._rate + 5.0),
            tooltip: 'Speed up',
            icon: const Icon(Icons.keyboard_arrow_up, size: 30)),
        IconButton(
            onPressed: () => parent.onRate(parent._rate - 5.0),
            tooltip: 'Slow down',
            icon: const Icon(Icons.keyboard_arrow_down, size: 30))
      ]),
      Text('%', style: _textStyle)
    ]));
  });
}

/// Renders album artwork or rate selector
Widget _rateCover(parent) {
  if (parent._showRatePicker == true) {
    String _message = 'Hide speed selector';
    GestureTapCallback _onTap = () {
      parent.setState(() => parent._showRatePicker = false);
    };
    const TextStyle _textStyle = TextStyle(fontSize: 30);
    if (parent._rate != 100.0) {
      _message = 'Reset player speed';
      _onTap = () => parent.onRate(100.0);
    }
    return Center(
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      Tooltip(
          message: _message,
          child: InkWell(
              onTap: _onTap,
              child: Text('${parent._rate.toInt()}', style: _textStyle))),
      Column(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
        IconButton(
            onPressed: () => parent.onRate(parent._rate + 5.0),
            tooltip: 'Speed up',
            icon: const Icon(Icons.keyboard_arrow_up, size: 30)),
        IconButton(
            onPressed: () => parent.onRate(parent._rate - 5.0),
            tooltip: 'Slow down',
            icon: const Icon(Icons.keyboard_arrow_down, size: 30))
      ]),
      const Text('%', style: _textStyle)
    ]));
  }
  Widget? _cover;
  if (parent.song != null) _cover = parent._getCover(parent.song);
  _cover ??= const Icon(Icons.music_note, size: 48.0);
  return Tooltip(
      message: 'Show speed selector',
      child: InkWell(
          onTap: () {
            parent.setState(() => parent._showRatePicker = true);
          },
          child: _cover));
}

/// Renders prelude length selector
Widget _preludePicker(parent) {
  return Builder(builder: (BuildContext context) {
    String _message = 'Reset intro length';
    if (parent._introLength == 0) _message = 'Set intro length';
    final TextStyle _textStyle = TextStyle(
        fontSize: 30, color: Theme.of(context).textTheme.bodyText2!.color);
    return Center(
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      Tooltip(
          message: _message,
          child: InkWell(
              onTap: () {
                parent.setState(() =>
                    parent._introLength = parent._introLength == 0 ? 10 : 0);
              },
              child: Text('${parent._introLength}', style: _textStyle))),
      Column(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
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
      Text('s', style: _textStyle)
    ]));
  });
}

/// Renders fade position selector
Widget _fadePositionPicker(parent) {
  return Builder(builder: (BuildContext context) {
    String _message = 'Reset fade position';
    if (parent._fadePosition == _emptyDuration) _message = 'Set fade position';
    final TextStyle _textStyle = TextStyle(
        fontSize: 30, color: Theme.of(context).textTheme.bodyText2!.color);
    return Center(
        child:
            Row(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
      Tooltip(
          message: _message,
          child: InkWell(
              onTap: () {
                parent.setState(() => parent._fadePosition =
                    parent._fadePosition == _emptyDuration
                        ? const Duration(seconds: 90)
                        : _emptyDuration);
              },
              child: Text(
                  '${parent._fadePosition.inMinutes}:${zero(parent._fadePosition.inSeconds % 60)}',
                  style: _textStyle))),
      Column(mainAxisAlignment: MainAxisAlignment.center, children: <Widget>[
        IconButton(
            onPressed: () {
              parent.setState(() => parent._fadePosition += _defaultDuration);
            },
            tooltip: 'Lengthen',
            icon: const Icon(Icons.keyboard_arrow_up, size: 30)),
        IconButton(
            onPressed: () {
              if (parent._fadePosition >= _defaultDuration) {
                parent.setState(() => parent._fadePosition -= _defaultDuration);
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
            parent.onRateDragStart(context, details),
        onVerticalDragUpdate: (DragUpdateDetails details) =>
            parent.onRateDragUpdate(context, details),
        onVerticalDragEnd: (DragEndDetails details) =>
            parent.onRateDragEnd(context, details),
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
                parent._rate,
                Theme.of(context).primaryColor)));
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
                children: <Widget>[
                  Text(_timeInfo(parent._queueComplete, parent._position),
                      style: TextStyle(
                          color: Theme.of(context).textTheme.bodyText2!.color,
                          fontWeight: FontWeight.bold)),
                  Text(
                      _timeInfo(
                          parent._queueComplete,
                          parent._fadePosition == _emptyDuration
                              ? parent.duration
                              : parent._fadePosition),
                      style: TextStyle(
                          color: parent._fadePosition == _emptyDuration
                              ? Theme.of(context).textTheme.bodyText2!.color
                              : youtubeColor,
                          fontWeight: parent._fadePosition == _emptyDuration
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
Widget _mainControl(_PlayerState parent) {
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
        children: <Widget>[
          Row(children: <Widget>[
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
          Row(children: <Widget>[
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
IconData _status(String _set) {
  switch (_set) {
    case 'all':
      return Icons.album;
    case '1':
      return Icons.music_note;
    default:
      return Icons.shuffle;
  }
}

String _timeInfo(int _queueComplete, Duration _time) {
  return _bad.contains(_queueComplete)
      ? '0:00'
      : '${_time.inMinutes}:${zero(_time.inSeconds % 60)}';
}

/// Renders current folder's ancestors
Widget _navigation(_PlayerState parent) {
  final List<Widget> _row = [];

  final String _root = parent.source.root;
  String _path = parent.chosenFolder;
  if (_path == _root) _path += '/${parent.source.name} home';
  final Iterable<int> relatives = parent.getRelatives(_root, _path);
  int j = 0;
  final int length = relatives.length;
  String _title;
  int start = 0;
  while (j < length) {
    start = j - 1 < 0 ? _root.length : relatives.elementAt(j - 1);
    _title = _path.substring(start + 1, relatives.elementAt(j));
    if (j + 1 == length) {
      _row.add(InkWell(
          onTap: parent._pickFolder,
          child: Text(_title,
              style: TextStyle(color: Theme.of(parent.context).primaryColor))));
    } else {
      final int _end = relatives.elementAt(j);
      _row
        ..add(InkWell(
            onTap: () => parent.onFolder(_path.substring(0, _end)),
            child: Text(_title)))
        ..add(Text('>', style: TextStyle(color: unfocusedColor)));
    }
    j++;
  }
  return Tooltip(
      message: 'Change folder',
      child: Wrap(runSpacing: 8.0, spacing: 8.0, children: _row));
}

/// Renders queue list
Widget _songPicker(parent) {
  if (parent.source.id == -1)
    return const Center(child: Text('Not yet supported!'));

  late List<SongModel> _songList;
  if (parent.chosenFolder != parent.folder) {
    if (parent._tempQueueComplete == 0)
      return Center(
          child: Text('Loading...', style: TextStyle(color: unfocusedColor)));
    if (parent._tempQueueComplete == -1 && parent._tempQueue.isEmpty)
      return Center(
          child: Text('No songs in folder',
              style: TextStyle(color: unfocusedColor)));
    _songList = parent._tempQueue;
  } else {
    if (parent._queueComplete == 0)
      return Center(
          child: Text('No songs in folder',
              style: TextStyle(color: unfocusedColor)));
    if (parent._queueComplete == -2)
      return const Center(child: Text('Unable to retrieve songs!'));
    _songList = parent.queue;
  }
  return ListView.builder(
      key: PageStorageKey<int>(_songList.hashCode),
      itemCount: _songList.length,
      itemBuilder: (BuildContext context, int i) {
        final SongModel _song = _songList[i];
        return ListTile(
            selected: parent.song == _song,
            onTap: () {
              if (parent.chosenFolder != parent.folder) {
                parent
                  ..onFolder(parent.chosenFolder)
                  ..setState(() => parent.index = parent.queue.indexOf(_song))
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
                    aspectRatio: 8 / 7, child: _listCover(parent, _song))),
            title: Text(_song.title.replaceAll('_', ' '),
                overflow: TextOverflow.ellipsis, maxLines: 1),
            subtitle: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  Expanded(
                      child: Text(
                          _song.artist == '<unknown>' ? '' : _song.artist!,
                          style: const TextStyle(fontSize: 11.0),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1)),
                  Text(_timeInfo(
                      parent.chosenFolder != parent.folder
                          ? parent._tempQueueComplete
                          : parent._queueComplete,
                      Duration(milliseconds: _song.duration!)))
                ]),
            trailing: Icon(
                (parent.song == _song && parent._state == PlayerState.PLAYING)
                    ? Icons.pause
                    : Icons.play_arrow,
                size: 30.0));
      });
}

/// Renders album artworks for queue list
Widget _listCover(_PlayerState parent, SongModel _song) {
  final Widget? _cover = parent._getCover(_song);
  if (_cover != null) {
    return Material(
        clipBehavior: Clip.antiAlias,
        shape: parent._orientation == Orientation.portrait
            ? const _CubistShapeA()
            : const _CubistShapeC(),
        child: _cover);
  }
  return const Icon(Icons.music_note);
}

/// Cubist shape for player slider.
class CubistWave extends CustomPainter {
  /// Player slider constructor
  CubistWave(this.title, this.duration, this.position, this.rate, this.color);

  /// Song title to parse
  String title;

  /// Song duration
  Duration duration;

  /// Current playback position
  Duration position;

  /// Playback rate to adjust duration
  double rate;

  /// Rendering color
  Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Map<int, double> _waveList = wave(title).asMap();
    final int _len = _waveList.length - 1;
    if (duration == _emptyDuration) {
      duration = _defaultDuration;
    } else if (duration.inSeconds == 0) {
      duration = const Duration(seconds: 1);
    }
    final double percentage = position.inSeconds / duration.inSeconds;

    final Path _songPath = Path()..moveTo(.0, size.height);
    _waveList.forEach((int index, double value) {
      _songPath.lineTo((size.width * index) / _len,
          size.height - _heightFactor(size.height, rate, value));
    });
    _songPath
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(_songPath, Paint()..color = color.withOpacity(.7));

    final Path _indicatorPath = Path();
    final double pos = _len * percentage;
    final int ceil = pos.ceil();
    _indicatorPath.moveTo(.0, size.height);
    _waveList.forEach((int index, double value) {
      if (index < ceil) {
        _indicatorPath.lineTo((size.width * index) / _len,
            size.height - _heightFactor(size.height, rate, value));
      } else if (index == ceil) {
        final double previous =
            index == 0 ? size.height : _waveList[index - 1]!;
        final double diff = value - previous;
        final double advance = 1 - (ceil - pos);
        _indicatorPath.lineTo(
            size.width * percentage,
            size.height -
                _heightFactor(size.height, rate, previous + (diff * advance)));
      }
    });
    _indicatorPath
      ..lineTo(size.width * percentage, size.height)
      ..close();
    canvas.drawPath(_indicatorPath, Paint()..color = color);
  }

  @override
  bool shouldRepaint(CubistWave oldDelegate) => true;
}

/// Generates wave data for slider
List<double> wave(String s) {
  List<double> _codes = [];
  s.toLowerCase().codeUnits.forEach((final int _code) {
    if (_code >= 48) _codes.add(_code.toDouble());
  });

  final double minCode = _codes.reduce(min);
  final double maxCode = _codes.reduce(max);

  _codes.asMap().forEach((int index, double value) {
    value = value - minCode;
    final double fraction = (100.0 / (maxCode - minCode)) * value;
    _codes[index] = fraction.roundToDouble();
  });

  final int _codesCount = _codes.length;
  if (_codesCount > 10)
    _codes = _codes.sublist(0, 5) + _codes.sublist(_codesCount - 5);

  return _codes;
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
      /*..moveTo(rect.left, rect.top + rect.height / 10)
      ..lineTo(rect.left + rect.width / 2, rect.top)
      ..lineTo(rect.right, rect.top + rect.height / 10)
      ..lineTo(rect.right - rect.width / 20, rect.top + 11 * rect.height / 20)
      ..lineTo(rect.right, rect.bottom + rect.height / 20)
      ..lineTo(rect.right - rect.width / 2, rect.bottom - rect.height / 20)
      ..lineTo(rect.left, rect.bottom + rect.height / 20)
      ..lineTo(rect.left + rect.width / 20, rect.top + 11 * rect.height / 20)*/
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) => this;
}
