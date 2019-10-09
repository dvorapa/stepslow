/*
 TODO:
 * Count songs in folders (stackoverflow)
 * Fix album cover (GitHub)
 * Random queue
 * Drag seek & rate (video)
 * Fix SD card (after update, GitHub)
 ** YouTube
 ** A & B
 ** Paso Doble intro
*/
import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:audio/audio.dart';
import 'package:audioplayers/audioplayers.dart' as rate;
import 'package:flutter_audio_query/flutter_audio_query.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_file_manager/flutter_file_manager.dart';
import 'package:easy_dialogs/easy_dialogs.dart';
import 'package:typicons_flutter/typicons_flutter.dart';

void printLong(dynamic text) {
  text = text.toString();
  final Pattern pattern = RegExp('.{1,1023}');
  pattern.allMatches(text).forEach((match) => print(match.group(0)));
}

Color interactiveColor = Colors.orange[300];  // #FFB74D #FFA726 #E4273A
Color backgroundColor = Colors.white;
Color youTubeColor = Colors.red;
Color unfocusedColor = Colors.grey[400];
Color blackColor = Colors.black;

String deviceRoot = '/storage/emulated/0';
String sdCardRoot;

String zero(int n) {
  if (n >= 10) return "$n";
  return "0$n";
}

List<double> wave(String s) {
  List<double> codes = [];
  s.toLowerCase().codeUnits.forEach((int code) {
    if (code >= 48) {
      codes.add(code.toDouble());
    }
  });

  double minCode = codes.reduce(min);
  double maxCode = codes.reduce(max);

  codes.asMap().forEach((int index, double value) {
    value = value - minCode;
    double fraction = (100.0 / (maxCode - minCode)) * value;
    codes[index] = fraction.roundToDouble();
  });

  int codesCount = codes.length;
  if (codesCount > 10) {
    codes = codes.sublist(0, 5) + codes.sublist(codesCount - 5);
  }

  return codes;
}

class _CubistButton extends ShapeBorder {
  const _CubistButton();

  @override
  EdgeInsetsGeometry get dimensions {
    return const EdgeInsets.only();
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection textDirection}) {
    return getOuterPath(rect, textDirection: textDirection);
  }

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
  ShapeBorder scale(double t) {
    return null;
  }
}

class _CubistFrame extends ShapeBorder {
  const _CubistFrame();

  @override
  EdgeInsetsGeometry get dimensions {
    return const EdgeInsets.only();
  }

  @override
  Path getInnerPath(Rect rect, {TextDirection textDirection}) {
    return getOuterPath(rect, textDirection: textDirection);
  }

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
  ShapeBorder scale(double t) {
    return null;
  }
}

class Entry implements Comparable<Entry> {
  String path;
  String type = 'song';
  int songs = 0;

  Entry(this.path, this.type);

  @override
  int compareTo(Entry other) =>
      this.path.toLowerCase().compareTo(other.path.toLowerCase());

  @override
  String toString() => 'Entry( ${this.path} )';

  String get name => path.split('/').lastWhere((e) => e != '');
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
      home: Player(title: 'Player'),
    );
  }
}

class Player extends StatefulWidget {
  Player({Key key, this.title}) : super(key: key);

  final String title;

  @override
  _PlayerState createState() => _PlayerState();
}

class _PlayerState extends State<Player> {
  rate.AudioPlayer audioPlayer = rate.AudioPlayer();
  AudioPlayerState _state = AudioPlayerState.STOPPED;
  double _rate = 100;
  Duration _position = Duration();
  String _mode = 'loop';
  String _set = 'random';

  PageController _controller = PageController(initialPage: 1);

  List<String> _sources = ['Device'];
  bool _sdCard = false;
  // bool _youTube = false;
  String source = 'Device';
  String folder = '/storage/emulated/0/Music';
  int index = 0;
  SongInfo song;
  Duration duration = Duration();

  final FlutterAudioQuery audioQuery = FlutterAudioQuery();
  dynamic _queueComplete = 0;
  dynamic _songsComplete = 0;
  dynamic _deviceBrowseSongsComplete = 0;
  dynamic _deviceBrowseFoldersComplete = 0;
  dynamic _deviceBrowseComplete = 0;
  dynamic _sdCardBrowseSongsComplete = 0;
  dynamic _sdCardBrowseFoldersComplete = 0;
  dynamic _sdCardBrowseComplete = 0;
  List<SongInfo> queue = [];
  List<SongInfo> _songs = [];
  SplayTreeMap<Entry, SplayTreeMap> deviceBrowse = SplayTreeMap();
  SplayTreeMap<Entry, SplayTreeMap> sdCardBrowse = SplayTreeMap();

  StreamSubscription<AudioPlayerState> _playerStateSubscription;
  StreamSubscription<double> _playerPositionController;
  StreamSubscription<int> _playerBufferingSubscription;
  StreamSubscription<AudioPlayerError> _playerErrorSubscription;

  onPlay() {
    if (_state == AudioPlayerState.PAUSED) {
      audioPlayer.resume();
    } else {
      setState(() => song = queue[index]);
      audioPlayer.play(song.filePath);
    }
    onRate(_rate);
    setState(() => _state = AudioPlayerState.PLAYING);
  }

  onChange(int _index) {
    // ### onChange(_set == 'random' ? Random().nextInt(queue.length) : index + 1);
    int available = queue.length;
    setState(() {
      if (_index < 0) {
        index = _index + available;
      } else if (_index >= available) {
        index = _index - available;
      } else {
        index = _index;
      }
    });
    if (_state == AudioPlayerState.PLAYING) {
      onPlay();
    } else {
      onStop();
      setState(() {
        song = queue.length > 0 ? queue[index] : null;
        if (song != null)
          duration = Duration(milliseconds: int.parse(song.duration));
      });
    }
  }

  onStop() {
    audioPlayer.stop();
    setState(() {
      duration = Duration();
      _position = Duration();
      _state = AudioPlayerState.STOPPED;
    });
  }

  onRate(num rate) {
    _rate = rate.toDouble();
    if (_state == AudioPlayerState.PLAYING)
      audioPlayer.setPlaybackRate(playbackRate: _rate / 100.0);

    setState(() => _rate = _rate);
  }

  onPause() {
    audioPlayer.pause();
    setState(() => _state = AudioPlayerState.PAUSED);
  }

  onSeek(Duration value) => audioPlayer.seek(value);

  onFolder(String _folder) {
    if (folder != _folder) {
      queue = [];
      setState(() {
        index = 0;
        _queueComplete = 0;
      });
      if (_songsComplete == true || _songsComplete > 0) {
        for (SongInfo _song in _songs) {
          if (File(_song.filePath).parent.path == _folder) {
            queue.add(_song);
            setState(() => _queueComplete++);

            if (_queueComplete == 1) onChange(index);
          }
        }
        if (_queueComplete > 0) {
          setState(() => _queueComplete = true);
        } else {
          onStop();
          setState(() => song = null);
        }
      }
      setState(() => folder = _folder);
    }
  }

  onMode(context) {
    setState(() {
      _mode = _mode == 'loop' ? 'once' : 'loop';
    });
    Scaffold.of(context).showSnackBar(SnackBar(
        backgroundColor: backgroundColor,
        elevation: 0.0,
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

  onSet(context) {
    setState(() {
      switch (_set) {
        case '1':
          _set = 'all';
          break;
        case 'all':
          _set = 'random';
          break;
        default:
          _set = '1';
          break;
      }
    });
    Scaffold.of(context).showSnackBar(SnackBar(
        backgroundColor: backgroundColor,
        elevation: 0.0,
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
                      Text(' ' + _source,
                          style: TextStyle(color: youTubeColor)),
                    ],
                  );
                  break;
                case 'SD card':
                  return Row(
                    children: <Widget>[
                      Icon(Icons.sd_card),
                      Text(' ' + _source),
                    ],
                  );
                  break;
                default:
                  return Row(
                    children: <Widget>[
                      Icon(Icons.folder),
                      Text(' ' + _source),
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

  @override
  void initState() {
    audioPlayer.onPlayerCompletion.listen((event) {
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

    super.initState();

    void fillBrowse(String _path, String _root, SplayTreeMap browse,
        dynamic value, ValueChanged<dynamic> valueChanged, String type) {
      int _rootLength = _root.length;
      String relative = _path.substring(_rootLength);
      if (relative.startsWith('/')) relative = relative.substring(1) + '/';
      Iterable<int> relatives =
          '/'.allMatches(relative).map((m) => _rootLength + m.end);
      int j = 0;
      String relativeString;
      int length = type == 'song' ? relatives.length - 1 : relatives.length;
      while (j < length) {
        relativeString = _path.substring(0, relatives.elementAt(j));
        Entry entry = Entry(relativeString, type);
        if (type == 'song') ++entry.songs;
        if (!browse.containsKey(entry)) {
          browse[entry] = SplayTreeMap();
          setState(() => valueChanged(value++));
        } else {
          // ### update key
        }
        browse = browse[entry];
        j++;
      }
    }

    Stream<List<SongInfo>> _songStream =
        Stream.fromFuture(audioQuery.getSongs());
    _songStream.listen((List<SongInfo> _songList) {
      for (SongInfo _song in _songList) {
        String _songPath = _song.filePath;
        String _songFolder = File(_songPath).parent.path;
        // queue
        if (_songFolder == folder) {
          queue.add(_song);
          setState(() => _queueComplete++);

          if (_queueComplete == 1) {
            audioPlayer.setUrl(_songPath);
            setState(() => song = queue[0]);
          }
        }

        // _songs
        if (_songPath.startsWith(deviceRoot) ||
            (_sdCard && _songPath.startsWith(sdCardRoot))) {
          _songs.add(_song);
          setState(() => _songsComplete++);
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
      setState(() {
        _queueComplete = _queueComplete > 0 ? true : 0;
        _songsComplete = _songsComplete > 0 ? true : 0;
        if (_deviceBrowseFoldersComplete == true) {
          _deviceBrowseComplete = true;
          printLong(deviceBrowse);
        } else {
          _deviceBrowseSongsComplete =
              _deviceBrowseSongsComplete > 0 ? true : 0;
        }
        if (_sdCardBrowseFoldersComplete == true) {
          _sdCardBrowseComplete = true;
          printLong(sdCardBrowse);
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

    Stream<List<Directory>> _deviceBrowseStream = Stream.fromFuture(
        FileManager(root: Directory(deviceRoot)).dirsTree(excludeHidden: true));
    _deviceBrowseStream.listen((List<Directory> _deviceFolderList) {
      for (Directory _folder in _deviceFolderList) {
        fillBrowse(
            _folder.path,
            deviceRoot,
            deviceBrowse,
            _deviceBrowseFoldersComplete,
            (value) => _deviceBrowseFoldersComplete = value,
            'folder');
      }
    }, onDone: () {
      if (_deviceBrowseSongsComplete == true) {
        setState(() => _deviceBrowseComplete = true);
        printLong(deviceBrowse);
      } else {
        setState(() => _deviceBrowseFoldersComplete =
            _deviceBrowseFoldersComplete > 0 ? true : 0);
      }
    }, onError: (error) {
      setState(() => _deviceBrowseFoldersComplete = false);
      print(error);
    });

    Stream<Directory> _sdCardStream =
        Stream.fromFuture(getExternalStorageDirectory());
    _sdCardStream.listen((Directory _sdCardRoot) {
      String _sdCardRootPath = _sdCardRoot.path;
      if (_sdCardRootPath != deviceRoot) {
        print(_sdCardRootPath);
        setState(() {
          _sdCard = true;
          sdCardRoot = _sdCardRootPath;
        });
        _sources.add('SD card');
      }
    }, onDone: () {
      if (_sdCard) {
        Stream<List<Directory>> _sdCardBrowseStream = Stream.fromFuture(
            FileManager(root: Directory(sdCardRoot))
                .dirsTree(excludeHidden: true));
        _sdCardBrowseStream.listen((List<Directory> _sdCardFolderList) {
          for (Directory _folder in _sdCardFolderList) {
            fillBrowse(
                _folder.path,
                sdCardRoot,
                sdCardBrowse,
                _sdCardBrowseFoldersComplete,
                (value) => _sdCardBrowseFoldersComplete = value,
                'folder');
          }
        }, onDone: () {
          if (_sdCardBrowseSongsComplete == true) {
            setState(() => _sdCardBrowseComplete = true);
            printLong(sdCardBrowse);
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

    Stream<List<InternetAddress>> youTubeStream =
        Stream.fromFuture(InternetAddress.lookup('youtube.com'));
    youTubeStream.listen((List<InternetAddress> result) {
      if (result.isNotEmpty && result[0].rawAddress.isNotEmpty) {
        /*
        setState(() => _youTube = true);
        _sources.add('YouTube');
        */
      }
    }, onError: (error) => print(error));
  }

  @override
  void dispose() {
    _playerStateSubscription.cancel();
    _playerPositionController.cancel();
    _playerBufferingSubscription.cancel();
    _playerErrorSubscription.cancel();
    audioPlayer.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: _controller,
      physics: BouncingScrollPhysics(),
      children: <Widget>[
        Scaffold(
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
        ),
        Scaffold(
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
              Expanded(child: SizedBox.shrink()),
              Material(
                clipBehavior: Clip.antiAlias,
                elevation: 2.0,
                shape: _CubistFrame(),
                child: SizedBox(
                  width: 160.0,
                  height: 140.0,
                  child: _album(song),
                ),
              ),
              Expanded(child: SizedBox.shrink()),
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Tooltip(
                      message: '''Drag position horizontally to change it
Drag corners vertically to change speed''',
// Double tap to add prelude''',
                      child: GestureDetector(
                        onHorizontalDragStart: (DragStartDetails details) {},
                        onHorizontalDragUpdate: (DragUpdateDetails details) {},
                        onHorizontalDragEnd: (DragEndDetails details) {},
                        onVerticalDragStart: (DragStartDetails details) {},
                        onVerticalDragUpdate: (DragUpdateDetails details) {},
                        onVerticalDragEnd: (DragEndDetails details) {},
                        onDoubleTap: () {},
                        child: CustomPaint(
                          size: Size.fromHeight(75.0),
                          painter: Wave(
                            [0, false].contains(_queueComplete)
                                ? 'zapaz'
                                : song.title,
                            [0, false].contains(_queueComplete)
                                ? Duration(seconds: 5)
                                : duration,
                            _position,
                          ),
                        ),
                      )),
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
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: <Widget>[
                                Text(
                                  [0, false].contains(_queueComplete)
                                      ? '0:00'
                                      : '${_position.inMinutes}:${zero(_position.inSeconds % 60)}',
                                  style: TextStyle(
                                      color: backgroundColor,
                                      fontWeight: FontWeight.bold),
                                ),
                                Text(
                                    [0, false].contains(_queueComplete)
                                        ? '0:00'
                                        : '${duration.inMinutes}:${zero(duration.inSeconds % 60)}',
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
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: <Widget>[
                                IconButton(
                                  onPressed: () => onChange(index - 1),
                                  tooltip: 'Previous',
                                  icon: Icon(Icons.skip_previous, size: 30.0),
                                ),
                                _play(this),
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
                                      /*
                                    Tooltip(
                                      message: 'Select start',
                                      child: InkWell(
                                        onTap: () {},
                                        child: Padding(
                                          padding: EdgeInsets.symmetric(
                                              horizontal: 20.0, vertical: 16.0),
                                          child: Text('A',
                                              style: TextStyle(
                                                  fontSize: 15.0,
                                                  fontWeight: FontWeight.bold,
                                                  color: backgroundColor)),
                                        )),),
                                    Tooltip(
                                      message: 'Select end',
                                      child: InkWell(
                                        onTap: () {},
                                        child: Padding(
                                          padding: EdgeInsets.symmetric(
                                              horizontal: 20.0, vertical: 16.0),
                                          child: Text('B',
                                              style: TextStyle(
                                                  fontSize: 15.0,
                                                  fontWeight: FontWeight.bold,
                                                  color: backgroundColor)),
                                        )),),
                                        */
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
        Scaffold(
          appBar: AppBar(
            leading: IconButton(
              onPressed: _returnToPlayer,
              tooltip: 'Back to player',
              icon: Icon(Icons.navigate_before),
            ),
            title: _folder(this),
          ),
          body: _songPicker(this),
        )
      ],
    );
  }
}

class Wave extends CustomPainter {
  String title;
  Duration duration;
  Duration position;
  Wave(this.title, this.duration, this.position);

  @override
  void paint(Canvas canvas, Size size) {
    List<double> _waveList = wave(title);
    int _len = _waveList.length - 1;
    if (duration == Duration()) {
      duration = Duration(seconds: 5);
    } else if (duration.inSeconds == 0) {
      duration = Duration(seconds: 1);
    }
    double percentage = position.inSeconds / duration.inSeconds;

    Path _songPath = Path();
    _songPath.moveTo(.0, size.height);
    _waveList.asMap().forEach((int index, double value) {
      _songPath.lineTo((size.width * index) / _len,
          (size.height / 3.0) + (size.height * (100.0 - value)) / 300.0);
    });
    _songPath.lineTo(size.width, size.height);
    _songPath.close();
    canvas.drawPath(
        _songPath, Paint()..color = interactiveColor.withOpacity(.7));

    Path _progressPath = Path();
    double pos = _len * percentage;
    int ceil = pos.ceil();
    _progressPath.moveTo(.0, size.height);
    _waveList.asMap().forEach((int index, double value) {
      if (index < ceil) {
        _progressPath.lineTo((size.width * index) / _len,
            (size.height / 3.0) + (size.height * (100.0 - value)) / 300.0);
      } else if (index == ceil) {
        double previous = index == 0 ? size.height : _waveList[index - 1];
        double diff = value - previous;
        double advance = 1 - (ceil - pos);
        _progressPath.lineTo(
            size.width * percentage,
            (size.height / 3.0) +
                (size.height * (100.0 - (previous + (diff * advance)))) /
                    300.0);
      }
    });
    _progressPath.lineTo(size.width * percentage, size.height);
    _progressPath.close();
    canvas.drawPath(_progressPath, Paint()..color = interactiveColor);
  }

  @override
  bool shouldRepaint(Wave oldDelegate) => false;
}

/* ###
                Column(
                  children: <Widget>[
                    Text('SPEED'),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        NumberPicker.integer(
                          initialValue: 100,
                          minValue: 5,
                          maxValue: 200,
                          step: 5,
                          onChanged: onRate,
                        ),
                        Text('%'),
                      ],
                    ),
                  ],
                ),
*/

Widget _folderPicker(parent) {
  if (parent.source == 'YouTube') {
    return Center(child: Text('Not yet supported'));
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
      return Center(child: Text('Unable to retrieve folders!'));
    } else {
      return ListView.builder(
          padding: EdgeInsets.all(16.0),
          itemCount: browse.length,
          itemBuilder: (BuildContext context, int i) {
            return _folderTile(parent, browse.entries.elementAt(i));
          });
    }
  }
}

Widget _folderTile(parent, MapEntry entry) {
  SplayTreeMap _children = entry.value;
  Entry _entry = entry.key;
  if (_children.isNotEmpty)
    return ExpansionTile(
      key: PageStorageKey<MapEntry>(entry),
      initiallyExpanded: parent.folder.contains(_entry.path),
      onExpansionChanged: (value) {
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
              text: '\n${_entry.songs} songs',
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
      children:
          _children.entries.map((entry) => _folderTile(parent, entry)).toList(),
    );
  return ListTile(
    selected: parent.folder == _entry.path,
    onTap: () => parent.onFolder(_entry.path),
    title: Text(
      _entry.name,
      style: TextStyle(
        fontSize: 14.0,
      ),
    ),
    subtitle: Text(
      '${_entry.songs} songs',
      style: TextStyle(
        fontSize: 10.0,
      ),
    ),
  );
}

Widget _songPicker(parent) {
  if (parent.source == 'YouTube') {
    return Center(child: Text('Not yet supported'));
  } else {
    if (parent._queueComplete == 0) {
      return Center(
          child:
              Text('No songs found', style: TextStyle(color: unfocusedColor)));
    } else if (parent._queueComplete == false) {
      return Center(child: Text('Unable to retrieve songs!'));
    } else {
      return ListView.builder(
        itemCount: parent.queue.length,
        itemBuilder: (BuildContext context, int i) {
          SongInfo _song = parent.queue[i];
          return ListTile(
            selected: parent.index == i,
            onTap: () {
              if (parent.index == i) {
                parent._changeState();
              } else {
                parent.onStop();
                parent.setState(() => parent.index = i);
                parent.onPlay();
              }
            },
            leading: _albumList(_song),
            title: Text(_song.title.replaceAll('_', ' '),
                overflow: TextOverflow.ellipsis, maxLines: 2),
            subtitle: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(_song.artist == '<unknown>' ? '' : '${_song.artist}',
                    style: TextStyle(fontSize: 11.0),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1),
                Text(
                    '${Duration(milliseconds: int.parse(_song.duration)).inMinutes}:${zero(Duration(milliseconds: int.parse(_song.duration)).inSeconds % 60)}'),
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

Widget _albumList(_song) {
  if (_song.albumArtwork != null) {
    return Image.file(File(_song.albumArtwork), fit: BoxFit.contain);
  } else {
    return FittedBox(
      child: Icon(Icons.music_note, size: 24.0),
    );
  }
}

Widget _album(_song) {
  if (_song != null && _song.albumArtwork != null) {
    return Image.file(File(_song.albumArtwork), fit: BoxFit.cover);
  } else {
    return Icon(Icons.music_note, size: 48.0, color: unfocusedColor);
  }
}

Color _sourceColor(parent) {
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

Widget _sourceButton(source) {
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

Widget _folder(parent) {
  String _location;
  if (['Device', 'SD card'].contains(parent.source)) {
    String _root = parent.source == 'SD card' ? sdCardRoot : deviceRoot;
    List<String> _locationList = parent.folder.split('/');
    List<String> _rootList = _root.split('/');
    _locationList = _locationList.sublist(_rootList.length);
    if (_locationList.isEmpty) {
      _location = parent.source + ' home';
    } else {
      _location = _locationList.join(' > ');
    }
  } else {
    _location = 'Autoplay';
  }
  return Tooltip(
    message: 'Change folder',
    child: InkWell(
      onTap: parent._pickFolder,
      child: Text(_location),
    ),
  );
}

Widget _title(parent) {
  if (parent._queueComplete == 0) {
    return Text('No songs found',
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

Widget _artist(parent) {
  if ([0, false].contains(parent._queueComplete) ||
      parent.song.artist == '<unknown>') {
    return SizedBox.shrink();
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

Widget _play(parent) {
  if (parent._queueComplete == 0) {
    return FloatingActionButton(
      onPressed: () {},
      tooltip: 'Loading...',
      shape: _CubistButton(),
      child: SizedBox(
        width: 20.0,
        height: 20.0,
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(interactiveColor),
        ),
      ),
    );
  } else if (parent._queueComplete == false) {
    return FloatingActionButton(
      onPressed: () {},
      tooltip: 'Unable to retrieve songs!',
      shape: _CubistButton(),
      foregroundColor: interactiveColor,
      child: Icon(Icons.close, size: 30.0),
    );
  } else {
    return FloatingActionButton(
      onPressed: parent._changeState,
      tooltip: parent._state == AudioPlayerState.PLAYING ? 'Pause' : 'Play',
      shape: _CubistButton(),
      foregroundColor: interactiveColor,
      child: Icon(
          parent._state == AudioPlayerState.PLAYING
              ? Icons.pause
              : Icons.play_arrow,
          size: 30.0),
    );
  }
}

IconData _status(_set) {
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
