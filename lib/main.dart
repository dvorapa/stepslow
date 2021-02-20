import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permissions_plugin/permissions_plugin.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_audio_query/flutter_audio_query.dart';
import 'package:flutter_file_manager/flutter_file_manager.dart';
import 'package:easy_dialogs/easy_dialogs.dart';
import 'package:typicons_flutter/typicons_flutter.dart';
import 'package:flutter_ffmpeg/flutter_ffmpeg.dart';
import 'package:yaml/yaml.dart';
import 'package:path_provider/path_provider.dart';

/// Theme main color
final Color interactiveColor = Colors.orange[300]; // #FFB74D #FFA726

/// Light theme color
final Color backgroundColor = Colors.white;

/// YouTube components color
final Color youTubeColor = Colors.red; // #E4273A

/// Text main color
final Color unfocusedColor = Colors.grey[400];

/// Dark theme color
final Color blackColor = Colors.black;

/// Duration initializer
Duration _emptyDuration = const Duration();

/// Default duration for empty queue
Duration _defaultDuration = const Duration(seconds: 5);

/// Default duration for animations
Duration _animationDuration = const Duration(milliseconds: 300);

/// Root folder of device
const String deviceRoot = '/storage/emulated/0';

/// Root folder of an SD card if any, provided by [getSdCardRoot()]
String sdCardRoot;

/// App folder for temporary files, provided by [getExternalCacheDirectories()]
String _tempFolder;

/// List of completer bad states
final List<dynamic> _bad = [0, false];

/// Prints long messages, e.g. maps
void printLong(dynamic text) {
  text = text.toString();
  final Pattern pattern = RegExp('.{1,1023}');
  for (final Match match in pattern.allMatches(text)) print(match.group(0));
}

/// Pads seconds
String zero(int n) {
  if (n >= 10) return '$n';
  return '0$n';
}

/// Calculates height factor for wave
double _heightFactor(double _height, double _rate, double _value) =>
    (_height / 400.0) * (3.0 * _rate / 2.0 + _value);

/// Finds sd card root folder(s) if any
Future<List<String>> getSdCardRoot() async {
  final List<String> result = [];
  final Directory storage = Directory('/storage');
  final List<FileSystemEntity> subDirs = storage.listSync();
  for (final Directory dir in subDirs) {
    try {
      final List<FileSystemEntity> subSubDirs = dir.listSync();
      if (subSubDirs.isNotEmpty) result.add(dir.path);
    } on FileSystemException {
      continue;
    }
  }
  return result;
}

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
  bool operator ==(dynamic other) => other is Entry && other.path == path;

  @override
  int get hashCode => path.hashCode;

  /// Entry name
  String get name {
    if ([deviceRoot, sdCardRoot].contains(path)) return '';

    return path.split('/').lastWhere((String e) => e != '');
  }
}

/// Starts app
void main() => runApp(const Stepslow());

/// Stateless app entrypoint and theme initializer.
class Stepslow extends StatelessWidget {
  /// Stepslow constructor
  const Stepslow({Key key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        title: 'Stepslow music player',
        theme: ThemeData(
            primaryColor: interactiveColor,
            accentColor: interactiveColor,
            appBarTheme: AppBarTheme(
                color: Colors.transparent,
                elevation: .0,
                iconTheme: IconThemeData(color: unfocusedColor),
                textTheme: TextTheme(headline6: TextStyle(color: blackColor))),
            colorScheme: ColorScheme.light(
                secondary: interactiveColor, onSecondary: backgroundColor),
            visualDensity: VisualDensity.adaptivePlatformDensity),
        home: const Player(title: 'Player'));
  }
}

/// Stateful app entrypoint.
class Player extends StatefulWidget {
  /// Player constructor
  const Player({Key key, this.title}) : super(key: key);

  /// Basic app title
  final String title;

  @override
  _PlayerState createState() => _PlayerState();
}

/// State handler.
class _PlayerState extends State<Player> {
  /// Audio player entity
  final AudioPlayer audioPlayer = AudioPlayer();

  /// Current playback state
  AudioPlayerState _state = AudioPlayerState.STOPPED;

  /// Current playback rate
  double _rate = 100.0;

  /// Previous playback rate
  double _previousRate = 100.0;

  /// Current playback position
  Duration _position = _emptyDuration;

  /// Current playback mode
  String _mode = 'loop';

  /// Current playback set
  String _set = 'random';

  Orientation _orientation;

  /// False if [_rate] picker should be hidden
  bool _ratePicker = false;

  /// False if [_ratePicker] was false at last redraw
  bool _previousRatePicker = false;

  /// Timer to release [_ratePicker]
  Timer _ratePickerTimer;

  /// Random generator to shuffle queue after startup
  final Random random = Random();

  /// History of page transitions
  List<int> pageHistory = [1];

  /// [PageView] controller
  final PageController _controller = PageController(initialPage: 1);

  /// Available sources
  final List<String> _sources = ['Device'];

  /// False if SD card is not available
  bool _sdCard = false;

  /// False if YouTube is not available
  /*bool _youTube = false;*/

  /// Current playback source
  String source = 'Device';

  /// Current playback folder
  String folder = '/storage/emulated/0/Music';

  /// Current playback song
  SongInfo song;

  /// Previous playback song
  SongInfo _previousSong;

  /// Current song index in queue
  int index = 0;

  /// Current song duration
  Duration duration = _emptyDuration;

  /// File containing album artwork paths YAML map
  File _coversFile;

  /// YAML map of album artwork paths
  String _coversYaml = '---\n';

  /// Map representation of album artwork paths YAML map
  Map<String, int> _coversMap = {};

  /// Audio query entity
  final FlutterAudioQuery audioQuery = FlutterAudioQuery();

  /// FFmpeg entity to query album artworks
  final FlutterFFmpeg _flutterFFmpeg = FlutterFFmpeg();

  /// FFmpeg config
  final FlutterFFmpegConfig _flutterFFmpegConfig = FlutterFFmpegConfig();

  /// Queue completer
  dynamic _queueComplete = 0;

  /// Song stack completer
  dynamic _songsComplete = 0;

  /// Device song stack completer
  dynamic _deviceBrowseSongsComplete = 0;

  /// Device folder stack completer
  dynamic _deviceBrowseFoldersComplete = 0;

  /// Device stack completer
  dynamic _deviceBrowseComplete = 0;

  /// SD card song stack completer
  dynamic _sdCardBrowseSongsComplete = 0;

  /// SD card folder stack completer
  dynamic _sdCardBrowseFoldersComplete = 0;

  /// SD card stack completer
  dynamic _sdCardBrowseComplete = 0;

  /// Album artwork completer
  dynamic _coversComplete = 0;

  /// Temporary storage completer
  dynamic _tempFolderComplete = 0;

  /// Preferences storage completer
  dynamic _privateFolderComplete = 0;

  /// Current playback queue
  List<SongInfo> queue = [];

  /// Stack of available songs
  final List<SongInfo> _songs = [];

  /// Stack of filesystem entities inside device
  SplayTreeMap<Entry, SplayTreeMap> deviceBrowse = SplayTreeMap();

  /// Stack of filesystem entities inside SD card
  SplayTreeMap<Entry, SplayTreeMap> sdCardBrowse = SplayTreeMap();

  /// Initializes [song] playback
  void onPlay({bool quiet = false}) {
    if (_state == AudioPlayerState.PAUSED || quiet) {
      audioPlayer.resume();
    } else {
      setState(() => song = queue[index]);
      audioPlayer.play(song.filePath);
    }
    onRate(_rate);
    if (!quiet) setState(() => _state = AudioPlayerState.PLAYING);
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
    if (_state == AudioPlayerState.PLAYING) {
      onPlay();
    } else {
      onStop();
      setState(() {
        song = queue.isNotEmpty ? queue[index] : null;
        if (song != null)
          duration = Duration(milliseconds: int.parse(song.duration));
      });
    }
  }

  /// Pauses [song] playback
  void onPause({bool quiet = false}) {
    audioPlayer.pause();
    if (!quiet) setState(() => _state = AudioPlayerState.PAUSED);
  }

  /// Shuts player down and resets its state
  void onStop() {
    audioPlayer.stop();
    setState(() {
      duration = _emptyDuration;
      _position = _emptyDuration;
      _state = AudioPlayerState.STOPPED;
    });
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
        for (final SongInfo _song in _songs) {
          if (File(_song.filePath).parent.path == _folder) {
            if (_set != 'random' || [0, 1].contains(_queueComplete)) {
              queue.add(_song);
            } else {
              queue.insert(1 + random.nextInt(_queueComplete), _song);
            }
            setState(() => ++_queueComplete);

            if (_queueComplete == 1) onChange(index);
          }
        }
        if (_queueComplete > 0) {
          setState(() => _queueComplete = true);
        } else {
          onStop();
          setState(() => song = null);
          if (_controller.page > .1) _pickFolder();
        }
      }
      setState(() => folder = _folder);
    }
  }

  /// Changes playback [_mode] and informs user using given [context]
  void onMode(StatelessElement context) {
    setState(() => _mode = _mode == 'loop' ? 'once' : 'loop');
    Scaffold.of(context).showSnackBar(SnackBar(
        backgroundColor: Theme.of(context).accentColor,
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

          index = queue.indexOf(song);
          _set = 'random';

          break;
        default:
          queue.sort(
              (SongInfo a, SongInfo b) => a.filePath.compareTo(b.filePath));

          index = queue.indexOf(song);
          _set = '1';

          break;
      }
    });

    Scaffold.of(context).showSnackBar(SnackBar(
        backgroundColor: Theme.of(context).accentColor,
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
    final RenderBox slider = context.findRenderObject();
    final Offset position = slider.globalToLocal(details.globalPosition);
    if (_state == AudioPlayerState.PLAYING) onPause(quiet: true);
    onSeek(position, duration, slider.constraints.biggest.width);
  }

  /// Listens seek drag actions
  void onPositionDragUpdate(
      BuildContext context, DragUpdateDetails details, Duration duration) {
    final RenderBox slider = context.findRenderObject();
    final Offset position = slider.globalToLocal(details.globalPosition);
    onSeek(position, duration, slider.constraints.biggest.width);
  }

  /// Ends to listen seek drag actions
  void onPositionDragEnd(
      BuildContext context, DragEndDetails details, Duration duration) {
    if (_state == AudioPlayerState.PLAYING) onPlay(quiet: true);
  }

  /// Listens seek tap actions
  void onPositionTapUp(
      BuildContext context, TapUpDetails details, Duration duration) {
    final RenderBox slider = context.findRenderObject();
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
    final RenderBox slider = context.findRenderObject();
    final Offset rate = slider.globalToLocal(details.globalPosition);
    if (_state == AudioPlayerState.PLAYING) onPause(quiet: true);
    updateRate(rate, slider.constraints.biggest.height);
  }

  /// Listens [_rate] drag actions
  void onRateDragUpdate(BuildContext context, DragUpdateDetails details) {
    final RenderBox slider = context.findRenderObject();
    final Offset rate = slider.globalToLocal(details.globalPosition);
    updateRate(rate, slider.constraints.biggest.height);
  }

  /// Ends to listen [_rate] drag actions
  void onRateDragEnd(BuildContext context, DragEndDetails details) {
    if (_state == AudioPlayerState.PLAYING) onPlay(quiet: true);
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
    audioPlayer.setPlaybackRate(playbackRate: rate / 100.0);
    setState(() {
      _position = _position * (_rate / rate);
      duration = duration * (_rate / rate);
      _rate = rate;
    });
  }

  /// Switches playback [_state]
  void _changeState() =>
      _state == AudioPlayerState.PLAYING ? onPause() : onPlay();

  /// Shows dialog to pick [source]
  void _pickSource() {
    showDialog(
        context: context,
        builder: (BuildContext context) {
          return SingleChoiceDialog<String>(
              isDividerEnabled: true,
              items: _sources,
              onSelected: (String _source) {
                setState(() => source = _source);
                String _folder;
                switch (_source) {
                  case 'YouTube':
                    _folder = '';
                    break;
                  case 'SD card':
                    _folder = sdCardRoot;
                    break;
                  default:
                    _folder = deviceRoot;
                    break;
                }
                onFolder(_folder);
              },
              itemBuilder: (String _source) {
                final Text _sourceText = source == _source
                    ? Text(_source,
                        style: TextStyle(color: Theme.of(context).primaryColor))
                    : Text(_source);
                switch (_source) {
                  case 'YouTube':
                    return Wrap(
                        spacing: 10.0,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        children: <Widget>[
                          Icon(Typicons.social_youtube,
                              color: source == _source
                                  ? Theme.of(context).primaryColor
                                  : youTubeColor),
                          _sourceText
                        ]);
                    break;
                  case 'SD card':
                    return Wrap(
                        spacing: 10.0,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        children: <Widget>[
                          Icon(Icons.sd_card,
                              color: source == _source
                                  ? Theme.of(context).primaryColor
                                  : Theme.of(context)
                                      .textTheme
                                      .bodyText2
                                      .color
                                      .withOpacity(.55)),
                          _sourceText
                        ]);
                    break;
                  default:
                    return Wrap(
                        spacing: 10.0,
                        crossAxisAlignment: WrapCrossAlignment.end,
                        children: <Widget>[
                          Icon(Icons.folder,
                              color: source == _source
                                  ? Theme.of(context).primaryColor
                                  : Theme.of(context)
                                      .textTheme
                                      .bodyText2
                                      .color
                                      .withOpacity(.55)),
                          _sourceText
                        ]);
                    break;
                }
              });
        });
  }

  /// Navigates to folder picker page
  void _pickFolder() => _controller.animateToPage(0,
      duration: _animationDuration, curve: Curves.ease);

  /// Navigates to song picker page
  void _pickSong() => _controller.animateToPage(2,
      duration: _animationDuration, curve: Curves.ease);

  /// Navigates to player main page
  void _returnToPlayer() => _controller.animateToPage(1,
      duration: _animationDuration, curve: Curves.ease);

  /// Goes back to the previous page
  bool onBack() {
    if (.9 < _controller.page && _controller.page < 1.1) {
      setState(() => pageHistory = [1]);
      return true;
    }
    _controller.animateToPage(pageHistory[0],
        duration: _animationDuration, curve: Curves.ease);
    setState(() => pageHistory = [1]);
    return false;
  }

  /// Queries album artworks to cache if missing
  Future<void> _checkCovers() async {
    final int _height =
        (MediaQuery.of(context).size.shortestSide * 7 / 10).ceil();
    for (final SongInfo _song in _songs) {
      final String _songPath = _song.filePath;
      if (_songPath.startsWith(deviceRoot) ||
          (_sdCard && _songPath.startsWith(sdCardRoot))) {
        if (!_coversMap.containsKey(_songPath)) {
          await _flutterFFmpeg
              .execute(
                  '-i "$_songPath" -vf scale="-2:\'min($_height,ih)\'":flags=lanczos -an "$_tempFolder/${_song.id}.jpg"')
              .then((int _status) {
            _coversMap[_songPath] = _status;
            _coversYaml += '"$_songPath": $_status\n';
            setState(() => ++_coversComplete);
          });
        }
      }
    }
    _coversFile.writeAsString(_coversYaml); // ignore: unawaited_futures
    setState(() => _coversComplete = true);
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
      dynamic value,
      ValueChanged<dynamic> valueChanged,
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
        setState(() => valueChanged(++value));
      }
      if (type == 'song') entry.songs++;
      browse = browse[entry];
      j++;
    }
  }

  @override
  void initState() {
    _flutterFFmpegConfig.disableRedirection();

    audioPlayer.onDurationChanged.listen((Duration d) {
      setState(() => duration = d * (100.0 / _rate));
    });
    audioPlayer.onAudioPositionChanged.listen((Duration p) {
      setState(() => _position = p * (100.0 / _rate));
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
      setState(() {
        duration = _emptyDuration;
        _position = _emptyDuration;
        _state = AudioPlayerState.STOPPED;
      });
      print(error);
    });

    _controller.addListener(() {
      final double _modulo = _controller.page % 1;
      if (.9 < _modulo || _modulo < .1) {
        final int _page = _controller.page.round();
        if (!pageHistory.contains(_page)) {
          pageHistory.add(_page);
          while (pageHistory.length > 2) pageHistory.removeAt(0);
        }
      }
    });

    super.initState();

    Stream<Map<Permission, PermissionState>>.fromFuture(
            PermissionsPlugin.requestPermissions(
                [Permission.READ_EXTERNAL_STORAGE]))
        .listen((Map<Permission, PermissionState> status) {
      if (status[Permission.READ_EXTERNAL_STORAGE] != PermissionState.GRANTED) {
        SystemChannels.platform.invokeMethod('SystemNavigator.pop');
      } else {
        Stream<List<Directory>>.fromFuture(getExternalCacheDirectories())
            .listen((List<Directory> _tempFolders) {
          for (final Directory tempFolder in _tempFolders) {
            final String _tempFolderPath = tempFolder.path;
            if (_tempFolderPath.startsWith(deviceRoot)) {
              _tempFolder = _tempFolderPath;
              setState(() => _tempFolderComplete = true);
              if ((_songsComplete == true) && (_privateFolderComplete == true))
                _checkCovers();
            }
          }
        });
        Stream<List<Directory>>.fromFuture(getExternalStorageDirectories())
            .listen((List<Directory> _privateFolders) {
          for (final Directory privateFolder in _privateFolders) {
            final String _privateFolderPath = privateFolder.path;
            if (_privateFolderPath.startsWith(deviceRoot)) {
              setState(() {
                _coversFile = File('$_privateFolderPath/covers.yaml');
                _privateFolderComplete = true;
              });
              if (_coversFile.existsSync()) {
                setState(() {
                  _coversYaml = _coversFile.readAsStringSync();
                  _coversMap = Map<String, int>.from(
                      loadYaml(_coversYaml) ?? <String, int>{});
                });
              } else {
                _coversFile.createSync(recursive: true);
              }
              if ((_songsComplete == true) && (_tempFolderComplete == true))
                _checkCovers();
            }
          }
        });

        Stream<List<SongInfo>>.fromFuture(audioQuery.getSongs()).listen(
            (List<SongInfo> _songList) {
          for (final SongInfo _song in _songList) {
            final String _songPath = _song.filePath;
            final String _songFolder = File(_songPath).parent.path;
            // queue
            if (_songFolder == folder) {
              if (_set != 'random' || [0, 1].contains(_queueComplete)) {
                queue.add(_song);
              } else {
                queue.insert(1 + random.nextInt(_queueComplete), _song);
              }
              setState(() => ++_queueComplete);

              if (_queueComplete == 1) {
                audioPlayer.setUrl(_songPath);
                setState(() => song = queue[0]);
              }
            }

            // _songs
            if (_songPath.startsWith(deviceRoot) ||
                (_sdCard && _songPath.startsWith(sdCardRoot))) {
              _songs.add(_song);
              setState(() => ++_songsComplete);
            }

            // browse
            if (_songPath.startsWith(deviceRoot)) {
              fillBrowse(
                  _songPath,
                  deviceRoot,
                  deviceBrowse,
                  _deviceBrowseSongsComplete,
                  (value) => _deviceBrowseSongsComplete = value,
                  'song');
            } else if (_sdCard && _songPath.startsWith(sdCardRoot)) {
              fillBrowse(
                  _songPath,
                  sdCardRoot,
                  sdCardBrowse,
                  _sdCardBrowseSongsComplete,
                  (value) => _sdCardBrowseSongsComplete = value,
                  'song');
            }
          }
        }, onDone: () {
          if (_songsComplete > 0) {
            setState(() => _songsComplete = true);
            if ((_tempFolderComplete == true) &&
                (_privateFolderComplete == true)) _checkCovers();
          }
          setState(() {
            _queueComplete = _queueComplete > 0 ? true : 0;
            if (_deviceBrowseFoldersComplete == true) {
              _deviceBrowseComplete = true;
            } else {
              _deviceBrowseSongsComplete =
                  _deviceBrowseSongsComplete > 0 ? true : 0;
            }
            if (_sdCardBrowseFoldersComplete == true) {
              _sdCardBrowseComplete = true;
            } else {
              _sdCardBrowseSongsComplete =
                  _sdCardBrowseSongsComplete > 0 ? true : 0;
            }
          });
        }, onError: (error) {
          setState(() {
            _queueComplete = false;
            _songsComplete = false;
            _deviceBrowseComplete = false;
            _sdCardBrowseComplete = false;
          });
          print(error);
        });

        Stream<List<Directory>>.fromFuture(
                FileManager(root: Directory(deviceRoot))
                    .dirsTree(excludeHidden: true))
            .listen((List<Directory> _deviceFolderList) {
          for (final Directory _folder in _deviceFolderList) {
            fillBrowse(
                _folder.path,
                deviceRoot,
                deviceBrowse,
                _deviceBrowseFoldersComplete,
                (value) => _deviceBrowseFoldersComplete = value,
                'folder');
          }
        }, onDone: () {
          fillBrowse(
              deviceRoot,
              deviceRoot,
              deviceBrowse,
              _deviceBrowseFoldersComplete,
              (value) => _deviceBrowseFoldersComplete = value,
              'folder');
          setState(() {
            if (_deviceBrowseSongsComplete == true) {
              _deviceBrowseComplete = true;
            } else {
              _deviceBrowseFoldersComplete =
                  _deviceBrowseFoldersComplete > 0 ? true : 0;
            }
          });
        }, onError: (error) {
          setState(() => _deviceBrowseFoldersComplete = false);
          print(error);
        });

        Stream<List<String>>.fromFuture(getSdCardRoot()).listen(
            (List<String> _sdCardRoots) {
          for (final String _sdCardRootPath in _sdCardRoots) {
            setState(() {
              _sdCard = true;
              sdCardRoot = _sdCardRootPath;
            });
            _sources.add('SD card');
          }
        }, onDone: () {
          if (_sdCard) {
            Stream<List<Directory>>.fromFuture(
                    FileManager(root: Directory(sdCardRoot))
                        .dirsTree(excludeHidden: true))
                .listen((List<Directory> _sdCardFolderList) {
              for (final Directory _folder in _sdCardFolderList) {
                fillBrowse(
                    _folder.path,
                    sdCardRoot,
                    sdCardBrowse,
                    _sdCardBrowseFoldersComplete,
                    (value) => _sdCardBrowseFoldersComplete = value,
                    'folder');
              }
            }, onDone: () {
              fillBrowse(
                  sdCardRoot,
                  sdCardRoot,
                  sdCardBrowse,
                  _sdCardBrowseFoldersComplete,
                  (value) => _sdCardBrowseFoldersComplete = value,
                  'folder');
              setState(() {
                if (_sdCardBrowseSongsComplete == true) {
                  _sdCardBrowseComplete = true;
                } else {
                  _sdCardBrowseFoldersComplete =
                      _sdCardBrowseFoldersComplete > 0 ? true : 0;
                }
              });
            }, onError: (error) {
              setState(() => _sdCardBrowseFoldersComplete = false);
              print(error);
            });
          }
        }, onError: (error) {
          setState(() => _sdCard = false);
          print(error);
        });
      }
    });

    /*Stream<List<InternetAddress>>.fromFuture(
            InternetAddress.lookup('youtube.com'))
        .listen((List<InternetAddress> result) {
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        setState(() => _youTube = true);
        _sources.add('YouTube');
      }
    }, onError: print);*/
  }

  @override
  void dispose() {
    audioPlayer.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_previousRate != _rate) {
      _ratePicker = true;
      _previousRate = _rate;
      _ratePickerTimer?.cancel();
      _ratePickerTimer = Timer(_defaultDuration, () {
        setState(() => _ratePicker = false);
      });
    }
    if (_previousSong != song) {
      _ratePicker = false;
      _previousSong = song;
      _ratePickerTimer?.cancel();
    }
    if (_previousRatePicker != _ratePicker) {
      _ratePickerTimer?.cancel();
      _ratePickerTimer = Timer(_defaultDuration, () {
        setState(() => _ratePicker = false);
      });
    }
    _previousRatePicker = _ratePicker;
    _orientation = MediaQuery.of(context).orientation;
    return Material(
        child: PageView(
            controller: _controller,
            physics: const BouncingScrollPhysics(),
            children: <Widget>[
          WillPopScope(
              onWillPop: () => Future<bool>.sync(onBack),
              child: Scaffold(
                  appBar: AppBar(
                      leading: IconButton(
                          tooltip: 'Change source',
                          onPressed: _pickSource,
                          icon: _sourceButton(
                              source,
                              Theme.of(context)
                                  .textTheme
                                  .bodyText2
                                  .color
                                  .withOpacity(.55))),
                      title: Tooltip(
                          message: 'Change source',
                          child:
                              InkWell(onTap: _pickSource, child: Text(source))),
                      actions: <Widget>[
                        IconButton(
                            onPressed: _returnToPlayer,
                            tooltip: 'Back to player',
                            icon: const Icon(Icons.navigate_next))
                      ]),
                  body: _folderPicker(this),
                  floatingActionButton: Align(
                      alignment: const Alignment(.8, .8),
                      child: Transform.scale(
                          scale: 1.1,
                          child: _play(this, 6.0, 32.0, () {
                            _changeState();
                            if (_state == AudioPlayerState.PLAYING)
                              _returnToPlayer();
                          }))))),
          WillPopScope(
              onWillPop: () => Future<bool>.sync(onBack),
              child: Scaffold(
                  appBar: AppBar(
                      leading: IconButton(
                          onPressed: _pickFolder,
                          tooltip: 'Pick folder',
                          icon: const Icon(Icons.folder_open)),
                      actions: <Widget>[
                        IconButton(
                            onPressed: _pickSong,
                            tooltip: 'Pick song',
                            icon: const Icon(Icons.album))
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
                              Flexible(flex: 11, child: _playerOblong(this)),
                              Flexible(
                                  flex: 20,
                                  child: Container(
                                      color: Theme.of(context).primaryColor,
                                      padding: const EdgeInsets.fromLTRB(
                                          16.0, 12.0, 16.0, .0),
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
                                            child: Text(
                                                _timeInfo(
                                                    _queueComplete, duration),
                                                style: TextStyle(
                                                  color: Theme.of(context)
                                                      .scaffoldBackgroundColor,
                                                ))))
                                  ]))
                        ]))),
          WillPopScope(
              onWillPop: () => Future<bool>.sync(onBack),
              child: Scaffold(
                  appBar: AppBar(
                      leading: IconButton(
                          onPressed: _returnToPlayer,
                          tooltip: 'Back to player',
                          icon: const Icon(Icons.navigate_before)),
                      title: _navigation(this)),
                  body: _songPicker(this),
                  floatingActionButton: Align(
                      alignment: const Alignment(.8, .8),
                      child: Transform.scale(
                          scale: 1.1,
                          child: Builder(builder: (BuildContext context) {
                            return FloatingActionButton(
                                onPressed: () {
                                  if (_set == 'random') {
                                    setState(() {
                                      queue.shuffle();
                                      index = queue.indexOf(song);
                                    });
                                  } else {
                                    setState(() => _set = 'all');
                                    onSet(context);
                                  }
                                },
                                tooltip: 'Sort or shuffle',
                                shape: _orientation == Orientation.portrait
                                    ? const _CubistShapeB()
                                    : const _CubistShapeD(),
                                elevation: 6.0,
                                backgroundColor: unfocusedColor,
                                child: const Icon(Icons.shuffle, size: 26.0));
                          })))))
        ]));
  }
}

/// Picks appropriate [source] list icon according to source given
Widget _sourceButton(String source, Color darkColor) {
  switch (source) {
    case 'YouTube':
      return Icon(Typicons.social_youtube, color: youTubeColor);
      break;
    case 'SD card':
      return Icon(Icons.sd_card, color: darkColor);
      break;
    default:
      return Icon(Icons.folder, color: darkColor);
      break;
  }
}

/// Renders folder list
Widget _folderPicker(_PlayerState parent) {
  if (parent.source == 'YouTube')
    return const Center(child: Text('Not yet supported'));

  dynamic _browseComplete;
  SplayTreeMap<Entry, SplayTreeMap> browse;
  if (parent.source == 'SD card') {
    _browseComplete = parent._sdCardBrowseComplete;
    browse = parent.sdCardBrowse;
  } else {
    _browseComplete = parent._deviceBrowseComplete;
    browse = parent.deviceBrowse;
  }
  if (_browseComplete == 0) {
    return Center(
        child:
            Text('No folders found', style: TextStyle(color: unfocusedColor)));
  } else if (_browseComplete == false) {
    return const Center(child: Text('Unable to retrieve folders!'));
  }
  return ListView.builder(
      padding: const EdgeInsets.all(16.0),
      itemCount: browse.length,
      itemBuilder: (BuildContext context, int i) =>
          _folderTile(parent, browse.entries.elementAt(i)));
}

/// Renders folder list tile
Widget _folderTile(_PlayerState parent, MapEntry<Entry, SplayTreeMap> entry) {
  final SplayTreeMap<Entry, SplayTreeMap> _children = entry.value;
  final Entry _entry = entry.key;
  if (_children.isNotEmpty) {
    return ExpansionTile(
        key: PageStorageKey<MapEntry>(entry),
        initiallyExpanded: parent.folder.contains(_entry.path),
        onExpansionChanged: (bool value) {
          if (value == true) parent.onFolder(_entry.path);
        },
        title: Text(_entry.name,
            style: TextStyle(
                fontSize: 14.0,
                color: parent.folder == _entry.path
                    ? Theme.of(parent.context).primaryColor
                    : Theme.of(parent.context).textTheme.bodyText2.color)),
        subtitle: Text(_entry.songs == 1 ? '1 song' : '${_entry.songs} songs',
            style: TextStyle(
                fontSize: 10.0,
                color: parent.folder == _entry.path
                    ? Theme.of(parent.context).primaryColor
                    : Theme.of(parent.context)
                        .textTheme
                        .bodyText2
                        .color
                        .withOpacity(.55))),
        children: _children.entries
            .map((MapEntry<Entry, SplayTreeMap> entry) =>
                _folderTile(parent, entry))
            .toList());
  }
  return ListTile(
      selected: parent.folder == _entry.path,
      onTap: () => parent.onFolder(_entry.path),
      title: _entry.name.isEmpty
          ? Align(
              alignment: Alignment.centerLeft,
              child: Icon(Icons.home,
                  color: parent.folder == _entry.path
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
    } else if (parent._queueComplete == false) {
      return FloatingActionButton(
          onPressed: () {},
          tooltip: 'Unable to retrieve songs!',
          shape: _shape,
          elevation: elevation,
          child: Icon(Icons.close, size: iconSize));
    }
    return FloatingActionButton(
        onPressed: onPressed,
        tooltip: parent._state == AudioPlayerState.PLAYING ? 'Pause' : 'Play',
        shape: _shape,
        elevation: elevation,
        child: Icon(
            parent._state == AudioPlayerState.PLAYING
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
              child: _rangeCover(parent))));
}

/// Renders album artwork or rate selector
Widget _rangeCover(parent) {
  if (parent._ratePicker == true) {
    String _message = 'Hide speed selector';
    dynamic _onTap = () => parent.setState(() => parent._ratePicker = false);
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
  Widget _cover = const Icon(Icons.music_note, size: 48.0);
  if (!_bad.contains(parent._tempFolderComplete) && parent.song != null) {
    final File _coverFile = File('$_tempFolder/${parent.song.id}.jpg');
    if (!_bad.contains(parent._coversComplete) &&
        parent._coversMap[parent.song.filePath] == 0 &&
        _coverFile.existsSync())
      _cover = Image.file(_coverFile, fit: BoxFit.cover);
  }
  return Tooltip(
      message: 'Show speed selector',
      child: InkWell(
          onTap: () => parent.setState(() => parent._ratePicker = true),
          child: _cover));
}

/// Handles oblong player section
Widget _playerOblong(_PlayerState parent) {
  return Builder(builder: (BuildContext context) {
    return Tooltip(
        message: '''
Drag position horizontally to change it
Drag curve vertically to change speed''',
/*Double tap to add prelude''',*/
        showDuration: _defaultDuration,
        waitDuration: _defaultDuration,
        child: GestureDetector(
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
            onVerticalDragStart: (DragStartDetails details) {
              parent.onRateDragStart(context, details);
            },
            onVerticalDragUpdate: (DragUpdateDetails details) {
              parent.onRateDragUpdate(context, details);
            },
            onVerticalDragEnd: (DragEndDetails details) {
              parent.onRateDragEnd(context, details);
            },
            /*onDoubleTap: () {},*/
            child: CustomPaint(
                size: Size.infinite,
                painter: CubistWave(
                    _bad.contains(parent._queueComplete)
                        ? 'zapaz'
                        : parent.song.title,
                    _bad.contains(parent._queueComplete)
                        ? _defaultDuration
                        : parent.duration,
                    parent._position,
                    parent._rate,
                    Theme.of(context).primaryColor))));
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
                          color: Theme.of(context).textTheme.bodyText2.color,
                          fontWeight: FontWeight.bold)),
                  Text(_timeInfo(parent._queueComplete, parent.duration),
                      style: TextStyle(
                          color: Theme.of(context).textTheme.bodyText2.color))
                ]),
            _title(parent),
            _artist(parent),
            _mainControl(parent),
            _minorControl(parent)
          ]);
    } else {
      return Column(children: <Widget>[
        _mainControl(parent),
        _minorControl(parent),
        Expanded(
            child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[_artist(parent), _title(parent)]))
      ]);
    }
  });
}

/// Renders current song title
Widget _title(_PlayerState parent) {
  return Builder(builder: (BuildContext context) {
    if (parent._queueComplete == 0) {
      return Text('Empty queue',
          style: TextStyle(
              color: Theme.of(context).textTheme.bodyText2.color,
              fontSize: 15.0));
    } else if (parent._queueComplete == false) {
      return Text('Unable to retrieve songs!',
          style: TextStyle(
              color: Theme.of(context).textTheme.bodyText2.color,
              fontSize: 15.0));
    }
    return Text(parent.song.title.replaceAll('_', ' ').toUpperCase(),
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
        textAlign: TextAlign.center,
        style: TextStyle(
            color: Theme.of(context).textTheme.bodyText2.color,
            fontSize: parent.song.artist == '<unknown>' ? 12.0 : 13.0,
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
        parent.song.artist == '<unknown>') return const SizedBox.shrink();

    return Text(parent.song.artist.toUpperCase(),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: TextStyle(
            color: Theme.of(context).textTheme.bodyText2.color,
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
                    child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20.0, vertical: 16.0),
                        child: Text('A',
                            style: TextStyle(
                                fontSize: 15.0,
                                fontWeight: FontWeight.bold))))),
            Tooltip(
                message: 'Select end',
                child: InkWell(
                    onTap: () {},
                    child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20.0, vertical: 16.0),
                        child: Text('B',
                            style: TextStyle(
                                fontSize: 15.0,
                                fontWeight: FontWeight.bold))))),*/
            IconButton(
                onPressed: () {
                  parent.onSet(context);
                },
                tooltip: 'Set (one, all, or random songs)',
                icon: Icon(_status(parent._set), size: 20.0))
          ]),
          Row(children: <Widget>[
            IconButton(
                onPressed: () {
                  parent.onMode(context);
                },
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
      break;
    case '1':
      return Icons.music_note;
      break;
    default:
      return Icons.shuffle;
      break;
  }
}

String _timeInfo(dynamic _queueComplete, Duration _time) {
  return _bad.contains(_queueComplete)
      ? '0:00'
      : '${_time.inMinutes}:${zero(_time.inSeconds % 60)}';
}

/// Renders current folder's ancestors
Widget _navigation(_PlayerState parent) {
  final List<Widget> _row = [];

  final String _root = parent.source == 'SD card' ? sdCardRoot : deviceRoot;
  String _path = parent.folder;
  if (_path == _root) _path += '/${parent.source} home';
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
  if (parent.source == 'YouTube')
    return const Center(child: Text('Not yet supported'));

  if (parent._queueComplete == 0) {
    return Center(
        child: Text('No songs in folder',
            style: TextStyle(color: unfocusedColor)));
  } else if (parent._queueComplete == false) {
    return const Center(child: Text('Unable to retrieve songs!'));
  }
  return ListView.builder(
      itemCount: parent.queue.length,
      itemBuilder: (BuildContext context, int i) {
        final SongInfo _song = parent.queue[i];
        return ListTile(
            selected: parent.index == i,
            onTap: () {
              if (parent.index == i) {
                parent._changeState();
              } else {
                parent
                  ..onStop()
                  ..setState(() => parent.index = i)
                  ..onPlay();
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
                          _song.artist == '<unknown>' ? '' : _song.artist,
                          style: const TextStyle(fontSize: 11.0),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1)),
                  Text(_timeInfo(
                      true, Duration(milliseconds: int.parse(_song.duration))))
                ]),
            trailing: Icon(
                (parent.index == i && parent._state == AudioPlayerState.PLAYING)
                    ? Icons.pause
                    : Icons.play_arrow,
                size: 30.0));
      });
}

/// Renders album artworks for queue list
Widget _listCover(_PlayerState parent, SongInfo _song) {
  if (!_bad.contains(parent._tempFolderComplete)) {
    final File _coverFile = File('$_tempFolder/${_song.id}.jpg');
    if (!_bad.contains(parent._coversComplete) &&
        parent._coversMap[_song.filePath] == 0 &&
        _coverFile.existsSync()) {
      return Material(
          clipBehavior: Clip.antiAlias,
          shape: parent._orientation == Orientation.portrait
              ? const _CubistShapeA()
              : const _CubistShapeC(),
          child: Image.file(_coverFile, fit: BoxFit.cover));
    }
  }
  return const Icon(Icons.music_note, size: 24.0);
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
    final List<double> _waveList = wave(title);
    final int _len = _waveList.length - 1;
    if (duration == _emptyDuration) {
      duration = _defaultDuration;
    } else if (duration.inSeconds == 0) {
      duration = const Duration(seconds: 1);
    }
    final double percentage = position.inSeconds / duration.inSeconds;

    final Path _songPath = Path()..moveTo(.0, size.height);
    _waveList.asMap().forEach((int index, double value) {
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
    _waveList.asMap().forEach((int index, double value) {
      if (index < ceil) {
        _indicatorPath.lineTo((size.width * index) / _len,
            size.height - _heightFactor(size.height, rate, value));
      } else if (index == ceil) {
        final double previous = index == 0 ? size.height : _waveList[index - 1];
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
  List<double> codes = [];
  for (final int code in s.toLowerCase().codeUnits) {
    if (code >= 48) codes.add(code.toDouble());
  }

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

  return codes;
}

/// Cubist shape for portrait album artworks.
/// ------
/// \    /
/// /    \
/// ------
class _CubistShapeA extends ShapeBorder {
  const _CubistShapeA();

  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.only();

  @override
  Path getInnerPath(Rect rect, {TextDirection textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection textDirection}) {
    return Path()
      ..moveTo(rect.left, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right - rect.width / 20.0, rect.top + rect.height / 2.0)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left + rect.width / 20.0, rect.top + rect.height / 2.0)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection textDirection}) {}

  @override
  ShapeBorder scale(double t) => null;
}

/// Cubist shape for portrait floating buttons.
///   ----
///  /  /
/// ----
class _CubistShapeB extends ShapeBorder {
  const _CubistShapeB();

  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.only();

  @override
  Path getInnerPath(Rect rect, {TextDirection textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection textDirection}) {
    return Path()
      ..moveTo(rect.left + rect.width / 5.0, rect.top + rect.height / 5.0)
      ..lineTo(rect.right - rect.width / 10.0, rect.top + rect.height / 10.0)
      ..lineTo(rect.right - rect.width / 5.0, rect.bottom - rect.height / 5.0)
      ..lineTo(rect.left + rect.width / 10.0, rect.bottom - rect.height / 10.0)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection textDirection}) {}

  @override
  ShapeBorder scale(double t) => null;
}

/// Cubist shape for landscape album artworks.
///  ______
/// /      \
/// \       \
///  \______/
class _CubistShapeC extends ShapeBorder {
  const _CubistShapeC();

  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.only();

  @override
  Path getInnerPath(Rect rect, {TextDirection textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection textDirection}) {
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
  void paint(Canvas canvas, Rect rect, {TextDirection textDirection}) {}

  @override
  ShapeBorder scale(double t) => null;
}

/// Cubist shape for landscape floating buttons.
/// ____
/// \  /
///  \/
class _CubistShapeD extends ShapeBorder {
  const _CubistShapeD();

  @override
  EdgeInsetsGeometry get dimensions => const EdgeInsets.only();

  @override
  Path getInnerPath(Rect rect, {TextDirection textDirection}) =>
      getOuterPath(rect, textDirection: textDirection);

  @override
  Path getOuterPath(Rect rect, {TextDirection textDirection}) {
    return Path()
      ..moveTo(rect.left - rect.width / 20, rect.top + rect.height / 6)
      ..lineTo(rect.right + rect.width / 20, rect.top + rect.height / 6)
      ..lineTo(rect.left + rect.width / 2, rect.bottom + rect.height / 20)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection textDirection}) {}

  @override
  ShapeBorder scale(double t) => null;
}
