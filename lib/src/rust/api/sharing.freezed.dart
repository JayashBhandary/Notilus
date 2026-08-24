// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'sharing.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$SmbServerEvent {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is SmbServerEvent);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'SmbServerEvent()';
  }
}

/// @nodoc
class $SmbServerEventCopyWith<$Res> {
  $SmbServerEventCopyWith(SmbServerEvent _, $Res Function(SmbServerEvent) __);
}

/// Adds pattern-matching-related methods to [SmbServerEvent].
extension SmbServerEventPatterns on SmbServerEvent {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>({
    TResult Function(SmbServerEvent_Started value)? started,
    TResult Function(SmbServerEvent_Stopped value)? stopped,
    TResult Function(SmbServerEvent_Connected value)? connected,
    TResult Function(SmbServerEvent_Authenticated value)? authenticated,
    TResult Function(SmbServerEvent_Rejected value)? rejected,
    TResult Function(SmbServerEvent_Disconnected value)? disconnected,
    TResult Function(SmbServerEvent_Transfer value)? transfer,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case SmbServerEvent_Started() when started != null:
        return started(_that);
      case SmbServerEvent_Stopped() when stopped != null:
        return stopped(_that);
      case SmbServerEvent_Connected() when connected != null:
        return connected(_that);
      case SmbServerEvent_Authenticated() when authenticated != null:
        return authenticated(_that);
      case SmbServerEvent_Rejected() when rejected != null:
        return rejected(_that);
      case SmbServerEvent_Disconnected() when disconnected != null:
        return disconnected(_that);
      case SmbServerEvent_Transfer() when transfer != null:
        return transfer(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>({
    required TResult Function(SmbServerEvent_Started value) started,
    required TResult Function(SmbServerEvent_Stopped value) stopped,
    required TResult Function(SmbServerEvent_Connected value) connected,
    required TResult Function(SmbServerEvent_Authenticated value) authenticated,
    required TResult Function(SmbServerEvent_Rejected value) rejected,
    required TResult Function(SmbServerEvent_Disconnected value) disconnected,
    required TResult Function(SmbServerEvent_Transfer value) transfer,
  }) {
    final _that = this;
    switch (_that) {
      case SmbServerEvent_Started():
        return started(_that);
      case SmbServerEvent_Stopped():
        return stopped(_that);
      case SmbServerEvent_Connected():
        return connected(_that);
      case SmbServerEvent_Authenticated():
        return authenticated(_that);
      case SmbServerEvent_Rejected():
        return rejected(_that);
      case SmbServerEvent_Disconnected():
        return disconnected(_that);
      case SmbServerEvent_Transfer():
        return transfer(_that);
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>({
    TResult? Function(SmbServerEvent_Started value)? started,
    TResult? Function(SmbServerEvent_Stopped value)? stopped,
    TResult? Function(SmbServerEvent_Connected value)? connected,
    TResult? Function(SmbServerEvent_Authenticated value)? authenticated,
    TResult? Function(SmbServerEvent_Rejected value)? rejected,
    TResult? Function(SmbServerEvent_Disconnected value)? disconnected,
    TResult? Function(SmbServerEvent_Transfer value)? transfer,
  }) {
    final _that = this;
    switch (_that) {
      case SmbServerEvent_Started() when started != null:
        return started(_that);
      case SmbServerEvent_Stopped() when stopped != null:
        return stopped(_that);
      case SmbServerEvent_Connected() when connected != null:
        return connected(_that);
      case SmbServerEvent_Authenticated() when authenticated != null:
        return authenticated(_that);
      case SmbServerEvent_Rejected() when rejected != null:
        return rejected(_that);
      case SmbServerEvent_Disconnected() when disconnected != null:
        return disconnected(_that);
      case SmbServerEvent_Transfer() when transfer != null:
        return transfer(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>({
    TResult Function(int field0)? started,
    TResult Function()? stopped,
    TResult Function(SmbConnectionEvent field0)? connected,
    TResult Function(SmbConnectionEvent field0)? authenticated,
    TResult Function(SmbConnectionEvent field0)? rejected,
    TResult Function(SmbConnectionEvent field0)? disconnected,
    TResult Function(SmbTransferEvent field0)? transfer,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case SmbServerEvent_Started() when started != null:
        return started(_that.field0);
      case SmbServerEvent_Stopped() when stopped != null:
        return stopped();
      case SmbServerEvent_Connected() when connected != null:
        return connected(_that.field0);
      case SmbServerEvent_Authenticated() when authenticated != null:
        return authenticated(_that.field0);
      case SmbServerEvent_Rejected() when rejected != null:
        return rejected(_that.field0);
      case SmbServerEvent_Disconnected() when disconnected != null:
        return disconnected(_that.field0);
      case SmbServerEvent_Transfer() when transfer != null:
        return transfer(_that.field0);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>({
    required TResult Function(int field0) started,
    required TResult Function() stopped,
    required TResult Function(SmbConnectionEvent field0) connected,
    required TResult Function(SmbConnectionEvent field0) authenticated,
    required TResult Function(SmbConnectionEvent field0) rejected,
    required TResult Function(SmbConnectionEvent field0) disconnected,
    required TResult Function(SmbTransferEvent field0) transfer,
  }) {
    final _that = this;
    switch (_that) {
      case SmbServerEvent_Started():
        return started(_that.field0);
      case SmbServerEvent_Stopped():
        return stopped();
      case SmbServerEvent_Connected():
        return connected(_that.field0);
      case SmbServerEvent_Authenticated():
        return authenticated(_that.field0);
      case SmbServerEvent_Rejected():
        return rejected(_that.field0);
      case SmbServerEvent_Disconnected():
        return disconnected(_that.field0);
      case SmbServerEvent_Transfer():
        return transfer(_that.field0);
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>({
    TResult? Function(int field0)? started,
    TResult? Function()? stopped,
    TResult? Function(SmbConnectionEvent field0)? connected,
    TResult? Function(SmbConnectionEvent field0)? authenticated,
    TResult? Function(SmbConnectionEvent field0)? rejected,
    TResult? Function(SmbConnectionEvent field0)? disconnected,
    TResult? Function(SmbTransferEvent field0)? transfer,
  }) {
    final _that = this;
    switch (_that) {
      case SmbServerEvent_Started() when started != null:
        return started(_that.field0);
      case SmbServerEvent_Stopped() when stopped != null:
        return stopped();
      case SmbServerEvent_Connected() when connected != null:
        return connected(_that.field0);
      case SmbServerEvent_Authenticated() when authenticated != null:
        return authenticated(_that.field0);
      case SmbServerEvent_Rejected() when rejected != null:
        return rejected(_that.field0);
      case SmbServerEvent_Disconnected() when disconnected != null:
        return disconnected(_that.field0);
      case SmbServerEvent_Transfer() when transfer != null:
        return transfer(_that.field0);
      case _:
        return null;
    }
  }
}

/// @nodoc

class SmbServerEvent_Started extends SmbServerEvent {
  const SmbServerEvent_Started(this.field0) : super._();

  final int field0;

  /// Create a copy of SmbServerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SmbServerEvent_StartedCopyWith<SmbServerEvent_Started> get copyWith =>
      _$SmbServerEvent_StartedCopyWithImpl<SmbServerEvent_Started>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SmbServerEvent_Started &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'SmbServerEvent.started(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $SmbServerEvent_StartedCopyWith<$Res>
    implements $SmbServerEventCopyWith<$Res> {
  factory $SmbServerEvent_StartedCopyWith(SmbServerEvent_Started value,
          $Res Function(SmbServerEvent_Started) _then) =
      _$SmbServerEvent_StartedCopyWithImpl;
  @useResult
  $Res call({int field0});
}

/// @nodoc
class _$SmbServerEvent_StartedCopyWithImpl<$Res>
    implements $SmbServerEvent_StartedCopyWith<$Res> {
  _$SmbServerEvent_StartedCopyWithImpl(this._self, this._then);

  final SmbServerEvent_Started _self;
  final $Res Function(SmbServerEvent_Started) _then;

  /// Create a copy of SmbServerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(SmbServerEvent_Started(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as int,
    ));
  }
}

/// @nodoc

class SmbServerEvent_Stopped extends SmbServerEvent {
  const SmbServerEvent_Stopped() : super._();

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType && other is SmbServerEvent_Stopped);
  }

  @override
  int get hashCode => runtimeType.hashCode;

  @override
  String toString() {
    return 'SmbServerEvent.stopped()';
  }
}

/// @nodoc

class SmbServerEvent_Connected extends SmbServerEvent {
  const SmbServerEvent_Connected(this.field0) : super._();

  final SmbConnectionEvent field0;

  /// Create a copy of SmbServerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SmbServerEvent_ConnectedCopyWith<SmbServerEvent_Connected> get copyWith =>
      _$SmbServerEvent_ConnectedCopyWithImpl<SmbServerEvent_Connected>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SmbServerEvent_Connected &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'SmbServerEvent.connected(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $SmbServerEvent_ConnectedCopyWith<$Res>
    implements $SmbServerEventCopyWith<$Res> {
  factory $SmbServerEvent_ConnectedCopyWith(SmbServerEvent_Connected value,
          $Res Function(SmbServerEvent_Connected) _then) =
      _$SmbServerEvent_ConnectedCopyWithImpl;
  @useResult
  $Res call({SmbConnectionEvent field0});
}

/// @nodoc
class _$SmbServerEvent_ConnectedCopyWithImpl<$Res>
    implements $SmbServerEvent_ConnectedCopyWith<$Res> {
  _$SmbServerEvent_ConnectedCopyWithImpl(this._self, this._then);

  final SmbServerEvent_Connected _self;
  final $Res Function(SmbServerEvent_Connected) _then;

  /// Create a copy of SmbServerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(SmbServerEvent_Connected(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as SmbConnectionEvent,
    ));
  }
}

/// @nodoc

class SmbServerEvent_Authenticated extends SmbServerEvent {
  const SmbServerEvent_Authenticated(this.field0) : super._();

  final SmbConnectionEvent field0;

  /// Create a copy of SmbServerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SmbServerEvent_AuthenticatedCopyWith<SmbServerEvent_Authenticated>
      get copyWith => _$SmbServerEvent_AuthenticatedCopyWithImpl<
          SmbServerEvent_Authenticated>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SmbServerEvent_Authenticated &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'SmbServerEvent.authenticated(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $SmbServerEvent_AuthenticatedCopyWith<$Res>
    implements $SmbServerEventCopyWith<$Res> {
  factory $SmbServerEvent_AuthenticatedCopyWith(
          SmbServerEvent_Authenticated value,
          $Res Function(SmbServerEvent_Authenticated) _then) =
      _$SmbServerEvent_AuthenticatedCopyWithImpl;
  @useResult
  $Res call({SmbConnectionEvent field0});
}

/// @nodoc
class _$SmbServerEvent_AuthenticatedCopyWithImpl<$Res>
    implements $SmbServerEvent_AuthenticatedCopyWith<$Res> {
  _$SmbServerEvent_AuthenticatedCopyWithImpl(this._self, this._then);

  final SmbServerEvent_Authenticated _self;
  final $Res Function(SmbServerEvent_Authenticated) _then;

  /// Create a copy of SmbServerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(SmbServerEvent_Authenticated(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as SmbConnectionEvent,
    ));
  }
}

/// @nodoc

class SmbServerEvent_Rejected extends SmbServerEvent {
  const SmbServerEvent_Rejected(this.field0) : super._();

  final SmbConnectionEvent field0;

  /// Create a copy of SmbServerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SmbServerEvent_RejectedCopyWith<SmbServerEvent_Rejected> get copyWith =>
      _$SmbServerEvent_RejectedCopyWithImpl<SmbServerEvent_Rejected>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SmbServerEvent_Rejected &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'SmbServerEvent.rejected(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $SmbServerEvent_RejectedCopyWith<$Res>
    implements $SmbServerEventCopyWith<$Res> {
  factory $SmbServerEvent_RejectedCopyWith(SmbServerEvent_Rejected value,
          $Res Function(SmbServerEvent_Rejected) _then) =
      _$SmbServerEvent_RejectedCopyWithImpl;
  @useResult
  $Res call({SmbConnectionEvent field0});
}

/// @nodoc
class _$SmbServerEvent_RejectedCopyWithImpl<$Res>
    implements $SmbServerEvent_RejectedCopyWith<$Res> {
  _$SmbServerEvent_RejectedCopyWithImpl(this._self, this._then);

  final SmbServerEvent_Rejected _self;
  final $Res Function(SmbServerEvent_Rejected) _then;

  /// Create a copy of SmbServerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(SmbServerEvent_Rejected(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as SmbConnectionEvent,
    ));
  }
}

/// @nodoc

class SmbServerEvent_Disconnected extends SmbServerEvent {
  const SmbServerEvent_Disconnected(this.field0) : super._();

  final SmbConnectionEvent field0;

  /// Create a copy of SmbServerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SmbServerEvent_DisconnectedCopyWith<SmbServerEvent_Disconnected>
      get copyWith => _$SmbServerEvent_DisconnectedCopyWithImpl<
          SmbServerEvent_Disconnected>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SmbServerEvent_Disconnected &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'SmbServerEvent.disconnected(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $SmbServerEvent_DisconnectedCopyWith<$Res>
    implements $SmbServerEventCopyWith<$Res> {
  factory $SmbServerEvent_DisconnectedCopyWith(
          SmbServerEvent_Disconnected value,
          $Res Function(SmbServerEvent_Disconnected) _then) =
      _$SmbServerEvent_DisconnectedCopyWithImpl;
  @useResult
  $Res call({SmbConnectionEvent field0});
}

/// @nodoc
class _$SmbServerEvent_DisconnectedCopyWithImpl<$Res>
    implements $SmbServerEvent_DisconnectedCopyWith<$Res> {
  _$SmbServerEvent_DisconnectedCopyWithImpl(this._self, this._then);

  final SmbServerEvent_Disconnected _self;
  final $Res Function(SmbServerEvent_Disconnected) _then;

  /// Create a copy of SmbServerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(SmbServerEvent_Disconnected(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as SmbConnectionEvent,
    ));
  }
}

/// @nodoc

class SmbServerEvent_Transfer extends SmbServerEvent {
  const SmbServerEvent_Transfer(this.field0) : super._();

  final SmbTransferEvent field0;

  /// Create a copy of SmbServerEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SmbServerEvent_TransferCopyWith<SmbServerEvent_Transfer> get copyWith =>
      _$SmbServerEvent_TransferCopyWithImpl<SmbServerEvent_Transfer>(
          this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SmbServerEvent_Transfer &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'SmbServerEvent.transfer(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $SmbServerEvent_TransferCopyWith<$Res>
    implements $SmbServerEventCopyWith<$Res> {
  factory $SmbServerEvent_TransferCopyWith(SmbServerEvent_Transfer value,
          $Res Function(SmbServerEvent_Transfer) _then) =
      _$SmbServerEvent_TransferCopyWithImpl;
  @useResult
  $Res call({SmbTransferEvent field0});
}

/// @nodoc
class _$SmbServerEvent_TransferCopyWithImpl<$Res>
    implements $SmbServerEvent_TransferCopyWith<$Res> {
  _$SmbServerEvent_TransferCopyWithImpl(this._self, this._then);

  final SmbServerEvent_Transfer _self;
  final $Res Function(SmbServerEvent_Transfer) _then;

  /// Create a copy of SmbServerEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(SmbServerEvent_Transfer(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as SmbTransferEvent,
    ));
  }
}

// dart format on
