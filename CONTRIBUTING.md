# Contributing

We love pull requests from everyone. Don't hesitate to create one if you want
to contribute code to the project.

Start by forking and cloning the repo:
```shellsession
$ git clone git@github.com:~your-username~/stepslow.git
```

You might want to make yourself familiar with Dart and Flutter environment
and commands, for that purpose you can use the [Flutter Getting Started Guide](
https://docs.flutter.dev/get-started/install).

Please always make sure you meet [Dart style guide](
https://dart.dev/guides/language/effective-dart/style). You can check
everything is in order running the following commands in project's root folder:
```shellsession
$ flutter format . && flutter analyze
```
or
```shellsession
$ dart format . && dart analyze
```

Also please always make sure you meet the following **design guidelines**:
- the whole app should be in alignment with [Material Design guidelines](
  https://material.io/design) and [minimalist](
  https://uxdesign.cc/a-guide-to-minimalist-design-36da72d52431)
- all raised buttons, floating buttons, and elevated widgets should have
  a cubist shape. You can use any of the shapes already in use or define
  your own
- all AppBars should have no visible borders. You might want to make them
  transparent and not elevated
- most of the icons used should be sharp-edged and outlined. You can use
  any of the icon fonts already imported
- you should pay attention to recurring themes inside the app and keep widgets
  of similar purpose similarly stylized

Please make sure to support the lowest version of Dart, Flutter, Android
and iOS possible. Also you should use the latest version of Android Studio,
its plugins and SDKs, Flutter and its packages available. Before any work
you might want to update your Android Studio setup and then Flutter setup using
the following commands in project's root folder:
```shellsession
$ flutter upgrade && flutter precache && flutter pub upgrade
```
If you changed launcher icons, you should run
`flutter pub run flutter_launcher_icons:main`. If you changed pubspec,
you should also run `flutter pub run pubspec_extract`.

Once you've made your modifications, you might want to make sure they work
properly. You can run them on a device or device simulator using the following
commands:
```shellsession
$ flutter clean  # always clean before building
$ flutter pub get
$ flutter run
```
Don't forget to test your changes in portrait as well as landscape mode.

Once you've made and might've tested your modifications, please double-check
them. You can use the following commands:
```shellsession
$ git status
$ git diff
```

Now you can commit your changes (`git add -A && git commit`). Please describe shortly
the commit in the first line and add a more detailed description underneath.
Any issue linked to the changes should be listed after the corresponding change
description.

Push to your fork (`git push`) and [submit a pull request](
https://github.com/dvorapa/stepslow/compare/).

At this point you're waiting on us. We like to at least comment
on pull requests within a week (and, typically, few days). We may suggest
some changes, improvements or alternatives. Once your pull request is merged,
it will be part of the next release and you will be listed as a contributor.

Feel free to ask any question or share any inconvenience with us so we can help
to make things easier for you.
