/*
 TODO:
 ** Authors
 ** Caching, preserve state
 *** YouTube
 *** A & B
 *** Paso Doble intro
 *** Color selection
*/
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

void printLong(dynamic text) {
  text = text.toString();
  final Pattern pattern = RegExp('.{1,1023}');
  for (final Match match in pattern.allMatches(text)) {
    print(match.group(0));
  }
}

final Color interactiveColor = Colors.orange[300]; // #FFB74D #FFA726 #E4273A
final Color backgroundColor = Colors.white;
final Color youTubeColor = Colors.red;
final Color unfocusedColor = Colors.grey[400];
final Color blackColor = Colors.black;

final String deviceRoot = '/storage/emulated/0';
String sdCardRoot;
//String _prefFolder;
String _tempFolder;

final List<dynamic> _empty = [0, false];

String zero(int n) {
  if (n >= 10) return '$n';
  return '0$n';
}

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
  if (codesCount > 10) {
    codes = codes.sublist(0, 5) + codes.sublist(codesCount - 5);
  }

  return codes;
}

Future<List<String>> getSdCardRoot() async {
  final List<String> result = [];
  final Directory storage = Directory('/storage');
  final List<FileSystemEntity> subDirs = storage.listSync();
  for (final Directory dir in subDirs) {
    try {
      final List<FileSystemEntity> subSubDirs = dir.listSync();
      if (subSubDirs.isNotEmpty) {
        result.add(dir.path);
      }
    } on FileSystemException {
      continue;
    }
  }
  return result;
}

class _CubistButton extends ShapeBorder {
  const _CubistButton();

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

class _CubistFrame extends ShapeBorder {
  const _CubistFrame();

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

class Entry implements Comparable<Entry> {
  Entry(this.path, this.type);

  String path;
  String type = 'song';
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

  String get name {
    if ([deviceRoot, sdCardRoot].contains(path)) {
      return '';
    } else {
      return path.split('/').lastWhere((String e) => e != '');
    }
  }
}

void main() => runApp(Stepslow());

class Stepslow extends StatelessWidget {
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
            iconTheme: IconThemeData(
              color: unfocusedColor,
            ),
            textTheme: TextTheme(
              title: TextStyle(color: blackColor),
            )),
      ),
      home: const Player(title: 'Player'),
    );
  }
}

class Player extends StatefulWidget {
  const Player({Key key, this.title}) : super(key: key);

  final String title;

  @override
  _PlayerState createState() => _PlayerState();
}

class _PlayerState extends State<Player> {
  final AudioPlayer audioPlayer = AudioPlayer();
  AudioPlayerState _state = AudioPlayerState.STOPPED;
  double _rate = 100.0;
  Duration _position = Duration();
  String _mode = 'loop';
  String _set = 'random';
  final Random random = Random();

  List<int> pageHistory = [1];
  final PageController _controller = PageController(initialPage: 1);

  List<String> _sources = ['Device'];
  bool _sdCard = false;
  //bool _youTube = false;
  String source = 'Device';
  String folder = '/storage/emulated/0/Music';
  int index = 0;
  SongInfo song;
  Duration duration = Duration();

  File _coversFile;
  String _coversYaml = '---\n';
  Map<String, int> _coversMap = {};

  final FlutterAudioQuery audioQuery = FlutterAudioQuery();
  final FlutterFFmpeg _flutterFFmpeg = FlutterFFmpeg();
  dynamic _queueComplete = 0;
  dynamic _songsComplete = 0;
  dynamic _deviceBrowseSongsComplete = 0;
  dynamic _deviceBrowseFoldersComplete = 0;
  dynamic _deviceBrowseComplete = 0;
  dynamic _sdCardBrowseSongsComplete = 0;
  dynamic _sdCardBrowseFoldersComplete = 0;
  dynamic _sdCardBrowseComplete = 0;
  dynamic _coversComplete = 0;
  dynamic _tempFolderComplete = 0;
  dynamic _privateFolderComplete = 0;
  List<SongInfo> queue = [];
  List<SongInfo> _songs = [];
  SplayTreeMap<Entry, SplayTreeMap> deviceBrowse = SplayTreeMap();
  SplayTreeMap<Entry, SplayTreeMap> sdCardBrowse = SplayTreeMap();

  void onPlay() {
    if (_state == AudioPlayerState.PAUSED) {
      audioPlayer.resume();
    } else {
      setState(() => song = queue[index]);
      audioPlayer.play(song.filePath);
    }
    onRate(_rate);
    setState(() => _state = AudioPlayerState.PLAYING);
  }

  void onChange(int _index) {
    final int available = queue.length;
    setState(() {
      if (_index < 0) {
        index = _index + available;
        if (_set == 'random' && queue.length > 2) {
          queue.shuffle();
          while (song == queue[index]) {
            queue.shuffle();
          }
        }
      } else if (_index >= available) {
        index = _index - available;
        if (_set == 'random' && queue.length > 2) {
          queue.shuffle();
          while (song == queue[index]) {
            queue.shuffle();
          }
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

  void onStop() {
    audioPlayer.stop();
    setState(() {
      duration = Duration();
      _position = Duration();
      _state = AudioPlayerState.STOPPED;
    });
  }

  void onPause() {
    audioPlayer.pause();
    setState(() => _state = AudioPlayerState.PAUSED);
  }

  void onFolder(String _folder) {
    if (folder != _folder) {
      queue.clear();
      setState(() {
        index = 0;
        _queueComplete = 0;
      });
      if (!_empty.contains(_songsComplete)) {
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

  void onMode(StatelessElement context) {
    setState(() {
      _mode = _mode == 'loop' ? 'once' : 'loop';
    });
    Scaffold.of(context).showSnackBar(SnackBar(
        backgroundColor: backgroundColor,
        elevation: .0,
        duration: Duration(seconds: 2),
        content: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(_mode == 'loop' ? 'playing in a loop ' : 'playing once ',
                style: TextStyle(color: interactiveColor)),
            Icon(_mode == 'loop' ? Icons.repeat : Icons.trending_flat,
                color: interactiveColor, size: 20.0),
          ],
        )));
  }

  void onSet(StatelessElement context) {
    switch (_set) {
      case '1':
        setState(() => _set = 'all');
        break;
      case 'all':
        queue.shuffle();

        setState(() {
          index = queue.indexOf(song);
          _set = 'random';
        });
        break;
      default:
        queue
            .sort((SongInfo a, SongInfo b) => a.filePath.compareTo(b.filePath));

        setState(() {
          index = queue.indexOf(song);
          _set = '1';
        });
        break;
    }

    Scaffold.of(context).showSnackBar(SnackBar(
        backgroundColor: backgroundColor,
        elevation: .0,
        duration: Duration(seconds: 2),
        content: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(_status(_set), color: interactiveColor, size: 20.0),
            Text(_set == '1' ? ' playing 1 song' : ' playing $_set songs',
                style: TextStyle(color: interactiveColor)),
          ],
        )));
  }

  void onSeek(Offset position, Duration duration, double width) {
    double newPosition = .0;

    if (position.dx <= 0) {
      newPosition = .0;
    } else if (position.dx >= width) {
      newPosition = width;
    } else {
      newPosition = position.dx;
    }

    setState(() {
      _position = duration * (newPosition / width);
    });

    audioPlayer.seek(_position);
  }

  void onPositionDragStart(
      BuildContext context, DragStartDetails details, Duration duration) {
    final RenderBox slider = context.findRenderObject();
    final Offset position = slider.globalToLocal(details.globalPosition);
    if (_state == AudioPlayerState.PLAYING) {
      onPause();
      setState(() => _state = AudioPlayerState.PLAYING);
    }
    onSeek(position, duration, MediaQuery.of(context).size.width);
  }

  void onPositionDragUpdate(
      BuildContext context, DragUpdateDetails details, Duration duration) {
    final RenderBox slider = context.findRenderObject();
    final Offset position = slider.globalToLocal(details.globalPosition);
    onSeek(position, duration, MediaQuery.of(context).size.width);
  }

  void onPositionDragEnd(
      BuildContext context, DragEndDetails details, Duration duration) {
    if (_state == AudioPlayerState.PLAYING) {
      setState(() => _state = AudioPlayerState.PAUSED);
      onPlay();
    }
  }

  void onPositionTapUp(
      BuildContext context, TapUpDetails details, Duration duration) {
    final RenderBox slider = context.findRenderObject();
    final Offset position = slider.globalToLocal(details.globalPosition);
    onSeek(position, duration, MediaQuery.of(context).size.width);
  }

  void onRate(double rate) {
    if (_state == AudioPlayerState.PLAYING)
      audioPlayer.setPlaybackRate(playbackRate: rate / 100.0);

    setState(() => _rate = rate);
  }

  void updateRate(Offset rate) {
    double newRate = 100.0;
    final double height = 120.0;

    if (rate.dy <= .0) {
      newRate = .0;
    } else if (rate.dy >= height) {
      newRate = height;
    } else {
      newRate = rate.dy;
    }

    _rate = 200.0 * (1 - (newRate / height));
    _rate = _rate - _rate % 5;
    if (_rate < 5) _rate = 5;
    onRate(_rate);
  }

  void onRateDragStart(BuildContext context, DragStartDetails details) {
    final RenderBox slider = context.findRenderObject();
    final Offset rate = slider.globalToLocal(details.globalPosition);
    if (_state == AudioPlayerState.PLAYING) {
      onPause();
      setState(() => _state = AudioPlayerState.PLAYING);
    }
    updateRate(rate);
  }

  void onRateDragUpdate(BuildContext context, DragUpdateDetails details) {
    final RenderBox slider = context.findRenderObject();
    final Offset rate = slider.globalToLocal(details.globalPosition);
    updateRate(rate);
  }

  void onRateDragEnd(BuildContext context, DragEndDetails details) {
    if (_state == AudioPlayerState.PLAYING) {
      setState(() => _state = AudioPlayerState.PAUSED);
      onPlay();
    }
  }

  void _changeState() =>
      _state == AudioPlayerState.PLAYING ? onPause() : onPlay();

  void _pickSource() {
    showDialog(
        context: context,
        builder: (BuildContext context) => SingleChoiceDialog<String>(
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
              switch (_source) {
                case 'YouTube':
                  return Row(
                    children: <Widget>[
                      Icon(Typicons.social_youtube, color: youTubeColor),
                      Text(' $_source', style: TextStyle(color: youTubeColor)),
                    ],
                  );
                  break;
                case 'SD card':
                  return Row(
                    children: <Widget>[
                      Icon(Icons.sd_card),
                      Text(' $_source'),
                    ],
                  );
                  break;
                default:
                  return Row(
                    children: <Widget>[
                      Icon(Icons.folder),
                      Text(' $_source'),
                    ],
                  );
                  break;
              }
            }));
  }

  void _pickFolder() => _controller.animateToPage(0,
      duration: Duration(milliseconds: 300), curve: Curves.ease);

  void _pickSong() => _controller.animateToPage(2,
      duration: Duration(milliseconds: 300), curve: Curves.ease);

  void _returnToPlayer() => _controller.animateToPage(1,
      duration: Duration(milliseconds: 300), curve: Curves.ease);

  bool onBack() {
    if (.9 < _controller.page && _controller.page < 1.1) {
      setState(() => pageHistory = [1]);
      return true;
    } else {
      _controller.animateToPage(
        pageHistory[0],
        duration: Duration(milliseconds: 300),
        curve: Curves.ease,
      );
      setState(() => pageHistory = [1]);
      return false;
    }
  }

  Future<void> _checkCovers() async {
    for (final SongInfo _song in _songs) {
      final String _songPath = _song.filePath;
      if (_songPath.startsWith(deviceRoot) ||
          (_sdCard && _songPath.startsWith(sdCardRoot))) {
        if (!_coversMap.containsKey(_songPath)) {
          await _flutterFFmpeg
              .execute(
                  '-i "$_songPath" -an -vcodec copy "$_tempFolder/${_song.id}.jpg"')
              .then((int _status) {
            _coversMap[_songPath] = _status;
            _coversYaml += '"$_songPath": $_status\n';
            setState(() => ++_coversComplete);
          });
        }
      }
    }
    _coversFile.writeAsString(_coversYaml);
    setState(() => _coversComplete = true);
  }

  @override
  void initState() {
    _flutterFFmpeg.disableRedirection();

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
    audioPlayer.onDurationChanged.listen((Duration d) {
      setState(() => duration = d * (100.0 / _rate));
    });
    audioPlayer.onAudioPositionChanged.listen((Duration p) {
      setState(() => _position = p * (100.0 / _rate));
    });
    audioPlayer.onPlayerError.listen((String error) {
      setState(() {
        duration = Duration();
        _position = Duration();
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
          while (pageHistory.length > 2) {
            pageHistory.removeAt(0);
          }
        }
      }
    });

    super.initState();

    void fillBrowse(
        String _path,
        String _root,
        SplayTreeMap<Entry, SplayTreeMap> browse,
        dynamic value,
        ValueChanged<dynamic> valueChanged,
        String type) {
      final int _rootLength = _root.length;
      String relative = _path.substring(_rootLength);
      if (relative.startsWith('/')) relative = '${relative.substring(1)}/';
      final Iterable<int> relatives =
          '/'.allMatches(relative).map((Match m) => _rootLength + m.end);
      int j = 0;
      String relativeString;
      num length = type == 'song' ? relatives.length - 1 : relatives.length;
      if (length == 0) length = .5;
      while (j < length) {
        if (length == .5) {
          relativeString = _root;
        } else {
          relativeString = _path.substring(0, relatives.elementAt(j));
        }
        Entry entry = Entry(relativeString, type);
        if (browse.containsKey(entry)) {
          entry = browse.keys.firstWhere((Entry key) => key == entry);
          if (type == 'song') entry.songs++;
        } else {
          browse[entry] = SplayTreeMap<Entry, SplayTreeMap>();
          setState(() => valueChanged(++value));
        }
        browse = browse[entry];
        j++;
      }
    }

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
                setState(() => _coversYaml = _coversFile.readAsStringSync());
                setState(() => _coversMap = Map<String, int>.from(
                    loadYaml(_coversYaml) ?? <String, int>{}));
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
          if (_deviceBrowseSongsComplete == true) {
            setState(() => _deviceBrowseComplete = true);
          } else {
            setState(() => _deviceBrowseFoldersComplete =
                _deviceBrowseFoldersComplete > 0 ? true : 0);
          }
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
              if (_sdCardBrowseSongsComplete == true) {
                setState(() => _sdCardBrowseComplete = true);
              } else {
                setState(() => _sdCardBrowseFoldersComplete =
                    _sdCardBrowseFoldersComplete > 0 ? true : 0);
              }
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
    }, onError: (error) => print(error));*/
  }

  @override
  void dispose() {
    audioPlayer.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
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
                  icon: _sourceButton(source)),
              title: Tooltip(
                message: 'Change source',
                child: InkWell(
                    onTap: _pickSource,
                    child: Text(source,
                        style: TextStyle(color: _sourceColor(this)))),
              ),
              actions: <Widget>[
                IconButton(
                  onPressed: _returnToPlayer,
                  tooltip: 'Back to player',
                  icon: Icon(Icons.navigate_next),
                ),
              ],
            ),
            body: _folderPicker(this),
            floatingActionButton: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Transform.scale(
                scale: 1.2,
                child: _play(this, 6.0, 32.0, backgroundColor, () {
                  _changeState();
                  if (_state == AudioPlayerState.PLAYING) _pickSong();
                }),
              ),
            ),
          ),
        ),
        WillPopScope(
          onWillPop: () => Future<bool>.sync(onBack),
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                onPressed: _pickFolder,
                tooltip: 'Pick folder',
                icon: Icon(Icons.folder_open),
              ),
              actions: <Widget>[
                IconButton(
                  onPressed: _pickSong,
                  tooltip: 'once',
                  icon: Icon(Icons.album),
                ),
              ],
            ),
            body: Column(
              children: <Widget>[
                const Expanded(child: SizedBox.shrink()),
                Material(
                  clipBehavior: Clip.antiAlias,
                  elevation: 2.0,
                  shape: const _CubistFrame(),
                  child: SizedBox(
                    width: 160.0,
                    height: 140.0,
                    child: _album(this),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Builder(builder: (BuildContext context) {
                      return Tooltip(
                          message: '''Drag position horizontally to change it
Drag curve vertically to change speed''',
//Double tap to add prelude''',
                          child: GestureDetector(
                            onHorizontalDragStart: (DragStartDetails details) {
                              onPositionDragStart(
                                  context,
                                  details,
                                  _empty.contains(_queueComplete)
                                      ? Duration(seconds: 5)
                                      : duration);
                            },
                            onHorizontalDragUpdate:
                                (DragUpdateDetails details) {
                              onPositionDragUpdate(
                                  context,
                                  details,
                                  _empty.contains(_queueComplete)
                                      ? Duration(seconds: 5)
                                      : duration);
                            },
                            onHorizontalDragEnd: (DragEndDetails details) {
                              onPositionDragEnd(
                                  context,
                                  details,
                                  _empty.contains(_queueComplete)
                                      ? Duration(seconds: 5)
                                      : duration);
                            },
                            onTapUp: (TapUpDetails details) {
                              onPositionTapUp(
                                  context,
                                  details,
                                  _empty.contains(_queueComplete)
                                      ? Duration(seconds: 5)
                                      : duration);
                            },
                            onVerticalDragStart: (DragStartDetails details) {
                              onRateDragStart(context, details);
                            },
                            onVerticalDragUpdate: (DragUpdateDetails details) {
                              onRateDragUpdate(context, details);
                            },
                            onVerticalDragEnd: (DragEndDetails details) {
                              onRateDragEnd(context, details);
                            },
                            //onDoubleTap: () {},
                            child: CustomPaint(
                              size: Size.fromHeight(120.0),
                              painter: Wave(
                                _empty.contains(_queueComplete)
                                    ? 'zapaz'
                                    : song.title,
                                _empty.contains(_queueComplete)
                                    ? Duration(seconds: 5)
                                    : duration,
                                _position,
                                _rate,
                              ),
                            ),
                          ));
                    }),
                    Theme(
                      data: ThemeData(
                        accentColor: backgroundColor,
                        iconTheme: IconThemeData(
                          color: backgroundColor,
                        ),
                      ),
                      isMaterialAppTheme: true,
                      child: Container(
                        height: 220.0,
                        color: interactiveColor,
                        child: Padding(
                          padding:
                              const EdgeInsets.fromLTRB(16.0, 12.0, 16.0, .0),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: <Widget>[
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: <Widget>[
                                  Text(
                                    _empty.contains(_queueComplete)
                                        ? '0:00'
                                        : '${_position.inMinutes}:'
                                            '${zero(_position.inSeconds % 60)}',
                                    style: TextStyle(
                                        color: backgroundColor,
                                        fontWeight: FontWeight.bold),
                                  ),
                                  Text(
                                      _empty.contains(_queueComplete)
                                          ? '0:00'
                                          : '${duration.inMinutes}:'
                                              '${zero(duration.inSeconds % 60)}',
                                      style: TextStyle(color: backgroundColor)),
                                ],
                              ),
                              Column(
                                children: <Widget>[
                                  _title(this),
                                  _artist(this),
                                ],
                              ),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: <Widget>[
                                  IconButton(
                                    onPressed: () => onChange(index - 1),
                                    tooltip: 'Previous',
                                    icon: Icon(Icons.skip_previous, size: 30.0),
                                  ),
                                  _play(this, 3.0, 30.0, interactiveColor,
                                      _changeState),
                                  IconButton(
                                    onPressed: () => onChange(index + 1),
                                    tooltip: 'Next',
                                    icon: Icon(Icons.skip_next, size: 30.0),
                                  ),
                                ],
                              ),
                              Builder(builder: (BuildContext context) {
                                return Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceEvenly,
                                  children: <Widget>[
                                    Row(
                                      children: <Widget>[
                                        /*Tooltip(
                                          message: 'Select start',
                                          child: InkWell(
                                              onTap: () {},
                                              child: Padding(
                                                padding: EdgeInsets.symmetric(
                                                    horizontal: 20.0,
                                                    vertical: 16.0),
                                                child: Text('A',
                                                    style: TextStyle(
                                                        fontSize: 15.0,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color:
                                                            backgroundColor)),
                                              )),
                                        ),
                                        Tooltip(
                                          message: 'Select end',
                                          child: InkWell(
                                              onTap: () {},
                                              child: Padding(
                                                padding: EdgeInsets.symmetric(
                                                    horizontal: 20.0,
                                                    vertical: 16.0),
                                                child: Text('B',
                                                    style: TextStyle(
                                                        fontSize: 15.0,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color:
                                                            backgroundColor)),
                                              )),
                                        ),*/
                                        IconButton(
                                          onPressed: () {
                                            onSet(context);
                                          },
                                          tooltip:
                                              'Set (one, all, or random songs)',
                                          icon: Icon(_status(_set), size: 20.0),
                                        ),
                                      ],
                                    ),
                                    Row(
                                      children: <Widget>[
                                        IconButton(
                                          onPressed: () {
                                            onMode(context);
                                          },
                                          tooltip: 'Mode (once or in a loop)',
                                          icon: Icon(
                                              _mode == 'loop'
                                                  ? Icons.repeat
                                                  : Icons.trending_flat,
                                              size: 20.0),
                                        ),
                                      ],
                                    ),
                                  ],
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        WillPopScope(
          onWillPop: () => Future<bool>.sync(onBack),
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                onPressed: _returnToPlayer,
                tooltip: 'Back to player',
                icon: Icon(Icons.navigate_before),
              ),
              title: _navigation(this),
            ),
            body: _songPicker(this),
          ),
        ),
      ],
    );
  }
}

class Wave extends CustomPainter {
  Wave(this.title, this.duration, this.position, this.rate);

  String title;
  Duration duration;
  Duration position;
  double rate;

  @override
  void paint(Canvas canvas, Size size) {
    final List<double> _waveList = wave(title);
    final int _len = _waveList.length - 1;
    if (duration == Duration()) {
      duration = Duration(seconds: 5);
    } else if (duration.inSeconds == 0) {
      duration = Duration(seconds: 1);
    }
    final double percentage = position.inSeconds / duration.inSeconds;

    final Path _songPath = Path()..moveTo(.0, size.height);
    _waveList.asMap().forEach((int index, double value) {
      _songPath.lineTo(
          (size.width * index) / _len,
          size.height -
              (((3.0 * size.height) / 4.0) * (rate / 200.0)) -
              ((size.height / 4.0) * (value / 100.0)));
    });
    _songPath
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(
        _songPath, Paint()..color = interactiveColor.withOpacity(.7));

    final Path _indicatorPath = Path();
    final double pos = _len * percentage;
    final int ceil = pos.ceil();
    _indicatorPath.moveTo(.0, size.height);
    _waveList.asMap().forEach((int index, double value) {
      if (index < ceil) {
        _indicatorPath.lineTo(
            (size.width * index) / _len,
            size.height -
                (((3.0 * size.height) / 4.0) * (rate / 200.0)) -
                ((size.height / 4.0) * (value / 100.0)));
      } else if (index == ceil) {
        final double previous = index == 0 ? size.height : _waveList[index - 1];
        final double diff = value - previous;
        final double advance = 1 - (ceil - pos);
        _indicatorPath.lineTo(
            size.width * percentage,
            size.height -
                (((3.0 * size.height) / 4.0) * (rate / 200.0)) -
                ((size.height / 4.0) *
                    ((previous + (diff * advance)) / 100.0)));
      }
    });
    _indicatorPath
      ..lineTo(size.width * percentage, size.height)
      ..close();
    canvas.drawPath(_indicatorPath, Paint()..color = interactiveColor);
  }

  @override
  bool shouldRepaint(Wave oldDelegate) => true;
}

Widget _folderPicker(_PlayerState parent) {
  if (parent.source == 'YouTube') {
    return Center(child: const Text('Not yet supported'));
  } else {
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
          child: Text('No folders found',
              style: TextStyle(color: unfocusedColor)));
    } else if (_browseComplete == false) {
      return Center(child: const Text('Unable to retrieve folders!'));
    } else {
      return ListView.builder(
          padding: const EdgeInsets.all(16.0),
          itemCount: browse.length,
          itemBuilder: (BuildContext context, int i) =>
              _folderTile(parent, browse.entries.elementAt(i)));
    }
  }
}

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
      title: RichText(
        text: TextSpan(
          text: _entry.name,
          style: TextStyle(
              fontSize: 14.0,
              color:
                  parent.folder == _entry.path ? interactiveColor : blackColor),
          children: <TextSpan>[
            TextSpan(
              text: _entry.songs == 1 ? '\n1 song' : '\n${_entry.songs} songs',
              style: TextStyle(
                fontSize: 10.0,
                color: parent.folder == _entry.path
                    ? interactiveColor
                    : Colors.grey[600],
                height: 2.0,
              ),
            ),
          ],
        ),
      ),
      children: _children.entries
          .map((MapEntry<Entry, SplayTreeMap> entry) =>
              _folderTile(parent, entry))
          .toList(),
    );
  }
  return ListTile(
    selected: parent.folder == _entry.path,
    onTap: () {
      parent.onFolder(_entry.path);
    },
    title: _entry.name.isEmpty
        ? Align(
            alignment: Alignment.centerLeft,
            child: Icon(Icons.home,
                color: parent.folder == _entry.path
                    ? interactiveColor
                    : unfocusedColor),
          )
        : Text(
            _entry.name,
            style: TextStyle(
              fontSize: 14.0,
            ),
          ),
    subtitle: Text(
      _entry.songs == 1 ? '1 song' : '${_entry.songs} songs',
      style: TextStyle(
        fontSize: 10.0,
      ),
    ),
  );
}

Widget _songPicker(parent) {
  if (parent.source == 'YouTube') {
    return Center(child: const Text('Not yet supported'));
  } else {
    if (parent._queueComplete == 0) {
      return Center(
          child: Text('No songs in folder',
              style: TextStyle(color: unfocusedColor)));
    } else if (parent._queueComplete == false) {
      return Center(child: const Text('Unable to retrieve songs!'));
    } else {
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
            leading: _albumList(parent, _song),
            title: Text(_song.title.replaceAll('_', ' '),
                overflow: TextOverflow.ellipsis, maxLines: 2),
            subtitle: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Expanded(
                  child: Text(
                      _song.artist == '<unknown>' ? '' : '${_song.artist}',
                      style: TextStyle(fontSize: 11.0),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1),
                ),
                Text(
                    '${Duration(milliseconds: int.parse(_song.duration)).inMinutes}:'
                    '${zero(Duration(milliseconds: int.parse(_song.duration)).inSeconds % 60)}'),
              ],
            ),
            trailing: Icon(
                (parent.index == i && parent._state == AudioPlayerState.PLAYING)
                    ? Icons.pause
                    : Icons.play_arrow,
                size: 30.0),
          );
        },
      );
    }
  }
}

Widget _albumList(_PlayerState parent, SongInfo _song) {
  if (!_empty.contains(parent._tempFolderComplete)) {
    final File _coverFile = File('$_tempFolder/${_song.id}.jpg');
    if (!_empty.contains(parent._coversComplete) &&
        parent._coversMap[_song.filePath] == 0 &&
        _coverFile.existsSync()) {
      return Material(
        clipBehavior: Clip.antiAlias,
        shape: const _CubistFrame(),
        child: Image.file(
          _coverFile,
          fit: BoxFit.cover,
          width: 40.0,
          height: 35.0,
        ),
      );
    }
  }
  return FittedBox(
    child: SizedBox(
        width: 40.0, height: 35.0, child: Icon(Icons.music_note, size: 24.0)),
  );
}

Widget _album(_PlayerState parent) {
  if (parent._rate != 100.0) {
    return Center(
        child: InkWell(
            onTap: () => parent.onRate(100.0),
            child: Text('${parent._rate.toInt()} %',
                style: TextStyle(fontSize: 30, color: unfocusedColor))));
  } else if (!_empty.contains(parent._tempFolderComplete) &&
      parent.song != null) {
    final File _coverFile = File('$_tempFolder/${parent.song.id}.jpg');
    if (!_empty.contains(parent._coversComplete) &&
        parent._coversMap[parent.song.filePath] == 0 &&
        _coverFile.existsSync()) {
      return Image.file(_coverFile, fit: BoxFit.cover);
    }
  }
  return Icon(Icons.music_note, size: 48.0, color: unfocusedColor);
}

Color _sourceColor(_PlayerState parent) {
  switch (parent.source) {
    case 'YouTube':
      return youTubeColor;
      break;
    case 'SD card':
      return parent.folder == sdCardRoot ? interactiveColor : blackColor;
      break;
    default:
      return parent.folder == deviceRoot ? interactiveColor : blackColor;
      break;
  }
}

Widget _sourceButton(String source) {
  switch (source) {
    case 'YouTube':
      return Icon(Typicons.social_youtube, color: youTubeColor);
      break;
    case 'SD card':
      return Icon(Icons.sd_card);
      break;
    default:
      return Icon(Icons.folder);
      break;
  }
}

Widget _navigation(_PlayerState parent) {
  final List<Widget> _row = [];

  final String _root = parent.source == 'SD card' ? sdCardRoot : deviceRoot;
  final int _rootLength = _root.length;
  String _path = '${parent.folder}';
  if (_path == _root) _path += '/${parent.source} home';
  String relative = _path.substring(_rootLength);
  if (relative.startsWith('/')) relative = '${relative.substring(1)}/';
  final Iterable<int> relatives =
      '/'.allMatches(relative).map((Match m) => _rootLength + m.end);
  int j = 0;
  final int length = relatives.length;
  String _title;
  int start = 0;
  while (j < length) {
    start = j - 1 < 0 ? _rootLength : relatives.elementAt(j - 1);
    _title = _path.substring(start + 1, relatives.elementAt(j));
    if (j + 1 == length) {
      _row.add(InkWell(
        onTap: parent._pickFolder,
        child: Text(_title, style: TextStyle(color: interactiveColor)),
      ));
    } else {
      final int _end = relatives.elementAt(j);
      _row
        ..add(InkWell(
          onTap: () => parent.onFolder(_path.substring(0, _end)),
          child: Text(_title),
        ))
        ..add(Text(' > ', style: TextStyle(color: unfocusedColor)));
    }
    j++;
  }
  return Tooltip(
    message: 'Change folder',
    child: Row(children: _row),
  );
}

Widget _title(_PlayerState parent) {
  if (parent._queueComplete == 0) {
    return Text('Empty queue',
        style: TextStyle(
          color: backgroundColor,
          fontSize: 15.0,
        ));
  } else if (parent._queueComplete == false) {
    return Text('Unable to retrieve songs!',
        style: TextStyle(
          color: backgroundColor,
          fontSize: 15.0,
        ));
  } else {
    return Text('${parent.song.title.replaceAll('_', ' ').toUpperCase()}',
        overflow: TextOverflow.ellipsis,
        maxLines: 2,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: backgroundColor,
          fontSize: parent.song.artist == '<unknown>' ? 12.0 : 13.0,
          letterSpacing: 6.0,
          fontWeight: FontWeight.bold,
        ));
  }
}

Widget _artist(_PlayerState parent) {
  if (_empty.contains(parent._queueComplete) ||
      parent.song.artist == '<unknown>') {
    return const SizedBox.shrink();
  } else {
    return Text(
      '${parent.song.artist.toUpperCase()}',
      overflow: TextOverflow.ellipsis,
      maxLines: 1,
      style: TextStyle(
        color: backgroundColor,
        fontSize: 9.0,
        height: 2.0,
        letterSpacing: 6.0,
      ),
    );
  }
}

Widget _play(_PlayerState parent, double elevation, double iconSize,
    Color foregroundColor, VoidCallback onPressed) {
  if (parent._queueComplete == 0) {
    return FloatingActionButton(
      onPressed: () {},
      tooltip: 'Loading...',
      shape: const _CubistButton(),
      elevation: elevation,
      child: SizedBox(
        width: iconSize - 10.0,
        height: iconSize - 10.0,
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(foregroundColor),
        ),
      ),
    );
  } else if (parent._queueComplete == false) {
    return FloatingActionButton(
      onPressed: () {},
      tooltip: 'Unable to retrieve songs!',
      shape: const _CubistButton(),
      elevation: elevation,
      foregroundColor: foregroundColor,
      child: Icon(Icons.close, size: iconSize),
    );
  } else {
    return FloatingActionButton(
      onPressed: onPressed,
      tooltip: parent._state == AudioPlayerState.PLAYING ? 'Pause' : 'Play',
      shape: const _CubistButton(),
      elevation: elevation,
      foregroundColor: foregroundColor,
      child: Icon(
          parent._state == AudioPlayerState.PLAYING
              ? Icons.pause
              : Icons.play_arrow,
          size: iconSize),
    );
  }
}

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
