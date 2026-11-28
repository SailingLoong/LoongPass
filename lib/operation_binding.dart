import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'operation_log.dart';

/// Hit-test metadata has no effect on focus, pointer handling or the AX tree.
enum OperationControl {
  accountSearch,
  accountFilter,
  accountSort,
  favorites,
  balance,
  modelSearch,
  pageSize;

  Widget mark(Widget child) => MetaData(metaData: this, child: child);
}

class OperationBinding extends WidgetsFlutterBinding
    with WidgetsBindingObserver {
  TextEditingController? _editor;
  final _sinceEdit = Stopwatch();
  String? _lastHover;
  Duration? _lastScroll;

  @override
  void initInstances() {
    super.initInstances();
    addObserver(this);
    addSemanticsEnabledListener(_semanticsChanged);
    addSemanticsActionListener(
      (action) => OperationLog.current?.record(
        'accessibility.action',
        target: action.type.name,
      ),
    );
    HardwareKeyboard.instance.addHandler(_key);
    FocusManager.instance.addListener(_focus);
    _semanticsChanged();
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      OperationLog.current?.recordError(
        'flutter.error',
        details.exception,
        details.stack,
      );
      onError?.call(details);
    };
    final onUnhandled = platformDispatcher.onError;
    platformDispatcher.onError = (error, stack) {
      OperationLog.current?.recordError('dart.error', error, stack);
      return onUnhandled?.call(error, stack) ?? false;
    };
  }

  void _semanticsChanged() => OperationLog.current?.record(
    'accessibility.state',
    target: semanticsEnabled ? 'enabled' : 'disabled',
  );

  @override
  void didChangeAppLifecycleState(ui.AppLifecycleState state) =>
      OperationLog.current?.record('app.lifecycle', target: state.name);

  void _focus() {
    final context = FocusManager.instance.primaryFocus?.context;
    final field = context?.findAncestorStateOfType<EditableTextState>()?.widget;
    _editor?.removeListener(_edit);
    _editor = field?.readOnly == false ? field!.controller : null;
    _editor?.addListener(_edit);
    _sinceEdit.stop();
    OperationLog.current?.record(
      'ui.focus',
      target: _editor == null ? 'control' : 'textField',
    );
  }

  void _edit() {
    // A burst is one edit, including IME and paste. Never access the field value.
    if (!_sinceEdit.isRunning || _sinceEdit.elapsedMilliseconds > 1000) {
      OperationLog.current?.record('ui.edit', target: 'textField');
    }
    _sinceEdit
      ..reset()
      ..start();
  }

  bool _key(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final shortcut = keyboard.isControlPressed || keyboard.isMetaPressed;
    final action = switch (key) {
      LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter => 'enter',
      LogicalKeyboardKey.escape => 'escape',
      LogicalKeyboardKey.tab =>
        keyboard.isShiftPressed ? 'previousFocus' : 'nextFocus',
      LogicalKeyboardKey.arrowUp ||
      LogicalKeyboardKey.arrowDown ||
      LogicalKeyboardKey.arrowLeft ||
      LogicalKeyboardKey.arrowRight => 'navigate',
      LogicalKeyboardKey.space when _editor == null => 'activate',
      LogicalKeyboardKey.keyV when shortcut => 'paste',
      LogicalKeyboardKey.keyC when shortcut => 'copy',
      LogicalKeyboardKey.keyX when shortcut => 'cut',
      LogicalKeyboardKey.keyZ when shortcut => 'undoRedo',
      LogicalKeyboardKey.keyA when shortcut => 'selectAll',
      _ => null,
    };
    if (action != null) OperationLog.current?.record('ui.key', target: action);
    return false;
  }

  @override
  void dispatchEvent(PointerEvent event, HitTestResult? hitTestResult) {
    if (OperationLog.current != null && hitTestResult != null) {
      _pointer(event, hitTestResult);
    }
    super.dispatchEvent(event, hitTestResult);
  }

  void _pointer(PointerEvent event, HitTestResult hits) {
    final String type;
    if (event is PointerDownEvent) {
      type = event.buttons == kSecondaryMouseButton ? 'contextPress' : 'press';
    } else if (event is PointerHoverEvent) {
      type = 'hover';
    } else if (event is PointerScrollEvent ||
        event is PointerPanZoomStartEvent) {
      final previous = _lastScroll;
      _lastScroll = event.timeStamp;
      if (previous != null &&
          event.timeStamp - previous < const Duration(milliseconds: 600))
        return;
      type = 'scroll';
    } else {
      return;
    }
    final target = _control(hits);
    if (type == 'hover') {
      if (target == _lastHover) return;
      _lastHover = target;
    }
    OperationLog.current?.record(
      'ui.$type',
      target: target,
      x: event.position.dx.round(),
      y: event.position.dy.round(),
    );
  }

  static String _control(HitTestResult hits) {
    var role = 'content';
    for (final entry in hits.path) {
      final object = entry.target;
      if (object is RenderMetaData && object.metaData is OperationControl) {
        return (object.metaData as OperationControl).name;
      }
      if (role != 'content') continue;
      if (object is RenderEditable) role = 'textField';
      if (object is RenderSemanticsAnnotations) {
        final props = object.properties;
        if (props.textField == true) role = 'textField';
        if (props.button == true || props.onTap != null) role = 'button';
        if (props.toggled != null || props.checked != null) role = 'toggle';
        if (props.slider == true) role = 'slider';
      }
    }
    return role;
  }
}

class OperationNavigation extends NavigatorObserver {
  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    final name = topRoute.settings.name;
    // Account route names include an identity. Only emit the route category.
    final kind = topRoute is PopupRoute
        ? 'dialog'
        : name?.startsWith('/accounts/') == true
        ? 'accountDetail'
        : topRoute.isFirst
        ? 'workspace'
        : 'page';
    OperationLog.current?.record('navigation.route', target: kind);
  }
}
