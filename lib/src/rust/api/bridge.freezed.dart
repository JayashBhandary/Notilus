// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'bridge.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$OpEvent {
  Object get field0;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is OpEvent &&
            const DeepCollectionEquality().equals(other.field0, field0));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(field0));

  @override
  String toString() {
    return 'OpEvent(field0: $field0)';
  }
}

/// @nodoc
class $OpEventCopyWith<$Res> {
  $OpEventCopyWith(OpEvent _, $Res Function(OpEvent) __);
}

/// Adds pattern-matching-related methods to [OpEvent].
extension OpEventPatterns on OpEvent {
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
    TResult Function(OpEvent_Progress value)? progress,
    TResult Function(OpEvent_Done value)? done,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case OpEvent_Progress() when progress != null:
        return progress(_that);
      case OpEvent_Done() when done != null:
        return done(_that);
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
    required TResult Function(OpEvent_Progress value) progress,
    required TResult Function(OpEvent_Done value) done,
  }) {
    final _that = this;
    switch (_that) {
      case OpEvent_Progress():
        return progress(_that);
      case OpEvent_Done():
        return done(_that);
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
    TResult? Function(OpEvent_Progress value)? progress,
    TResult? Function(OpEvent_Done value)? done,
  }) {
    final _that = this;
    switch (_that) {
      case OpEvent_Progress() when progress != null:
        return progress(_that);
      case OpEvent_Done() when done != null:
        return done(_that);
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
    TResult Function(OpProgress field0)? progress,
    TResult Function(OpOutcome field0)? done,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case OpEvent_Progress() when progress != null:
        return progress(_that.field0);
      case OpEvent_Done() when done != null:
        return done(_that.field0);
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
    required TResult Function(OpProgress field0) progress,
    required TResult Function(OpOutcome field0) done,
  }) {
    final _that = this;
    switch (_that) {
      case OpEvent_Progress():
        return progress(_that.field0);
      case OpEvent_Done():
        return done(_that.field0);
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
    TResult? Function(OpProgress field0)? progress,
    TResult? Function(OpOutcome field0)? done,
  }) {
    final _that = this;
    switch (_that) {
      case OpEvent_Progress() when progress != null:
        return progress(_that.field0);
      case OpEvent_Done() when done != null:
        return done(_that.field0);
      case _:
        return null;
    }
  }
}

/// @nodoc

class OpEvent_Progress extends OpEvent {
  const OpEvent_Progress(this.field0) : super._();

  @override
  final OpProgress field0;

  /// Create a copy of OpEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $OpEvent_ProgressCopyWith<OpEvent_Progress> get copyWith =>
      _$OpEvent_ProgressCopyWithImpl<OpEvent_Progress>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is OpEvent_Progress &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'OpEvent.progress(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $OpEvent_ProgressCopyWith<$Res>
    implements $OpEventCopyWith<$Res> {
  factory $OpEvent_ProgressCopyWith(
          OpEvent_Progress value, $Res Function(OpEvent_Progress) _then) =
      _$OpEvent_ProgressCopyWithImpl;
  @useResult
  $Res call({OpProgress field0});
}

/// @nodoc
class _$OpEvent_ProgressCopyWithImpl<$Res>
    implements $OpEvent_ProgressCopyWith<$Res> {
  _$OpEvent_ProgressCopyWithImpl(this._self, this._then);

  final OpEvent_Progress _self;
  final $Res Function(OpEvent_Progress) _then;

  /// Create a copy of OpEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(OpEvent_Progress(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as OpProgress,
    ));
  }
}

/// @nodoc

class OpEvent_Done extends OpEvent {
  const OpEvent_Done(this.field0) : super._();

  @override
  final OpOutcome field0;

  /// Create a copy of OpEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $OpEvent_DoneCopyWith<OpEvent_Done> get copyWith =>
      _$OpEvent_DoneCopyWithImpl<OpEvent_Done>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is OpEvent_Done &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'OpEvent.done(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $OpEvent_DoneCopyWith<$Res>
    implements $OpEventCopyWith<$Res> {
  factory $OpEvent_DoneCopyWith(
          OpEvent_Done value, $Res Function(OpEvent_Done) _then) =
      _$OpEvent_DoneCopyWithImpl;
  @useResult
  $Res call({OpOutcome field0});
}

/// @nodoc
class _$OpEvent_DoneCopyWithImpl<$Res> implements $OpEvent_DoneCopyWith<$Res> {
  _$OpEvent_DoneCopyWithImpl(this._self, this._then);

  final OpEvent_Done _self;
  final $Res Function(OpEvent_Done) _then;

  /// Create a copy of OpEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(OpEvent_Done(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as OpOutcome,
    ));
  }
}

/// @nodoc
mixin _$ScanEvent {
  Object get field0;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is ScanEvent &&
            const DeepCollectionEquality().equals(other.field0, field0));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(field0));

  @override
  String toString() {
    return 'ScanEvent(field0: $field0)';
  }
}

/// @nodoc
class $ScanEventCopyWith<$Res> {
  $ScanEventCopyWith(ScanEvent _, $Res Function(ScanEvent) __);
}

/// Adds pattern-matching-related methods to [ScanEvent].
extension ScanEventPatterns on ScanEvent {
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
    TResult Function(ScanEvent_Progress value)? progress,
    TResult Function(ScanEvent_Done value)? done,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case ScanEvent_Progress() when progress != null:
        return progress(_that);
      case ScanEvent_Done() when done != null:
        return done(_that);
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
    required TResult Function(ScanEvent_Progress value) progress,
    required TResult Function(ScanEvent_Done value) done,
  }) {
    final _that = this;
    switch (_that) {
      case ScanEvent_Progress():
        return progress(_that);
      case ScanEvent_Done():
        return done(_that);
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
    TResult? Function(ScanEvent_Progress value)? progress,
    TResult? Function(ScanEvent_Done value)? done,
  }) {
    final _that = this;
    switch (_that) {
      case ScanEvent_Progress() when progress != null:
        return progress(_that);
      case ScanEvent_Done() when done != null:
        return done(_that);
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
    TResult Function(ScanProgress field0)? progress,
    TResult Function(List<DuplicateGroup> field0)? done,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case ScanEvent_Progress() when progress != null:
        return progress(_that.field0);
      case ScanEvent_Done() when done != null:
        return done(_that.field0);
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
    required TResult Function(ScanProgress field0) progress,
    required TResult Function(List<DuplicateGroup> field0) done,
  }) {
    final _that = this;
    switch (_that) {
      case ScanEvent_Progress():
        return progress(_that.field0);
      case ScanEvent_Done():
        return done(_that.field0);
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
    TResult? Function(ScanProgress field0)? progress,
    TResult? Function(List<DuplicateGroup> field0)? done,
  }) {
    final _that = this;
    switch (_that) {
      case ScanEvent_Progress() when progress != null:
        return progress(_that.field0);
      case ScanEvent_Done() when done != null:
        return done(_that.field0);
      case _:
        return null;
    }
  }
}

/// @nodoc

class ScanEvent_Progress extends ScanEvent {
  const ScanEvent_Progress(this.field0) : super._();

  @override
  final ScanProgress field0;

  /// Create a copy of ScanEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $ScanEvent_ProgressCopyWith<ScanEvent_Progress> get copyWith =>
      _$ScanEvent_ProgressCopyWithImpl<ScanEvent_Progress>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is ScanEvent_Progress &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'ScanEvent.progress(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $ScanEvent_ProgressCopyWith<$Res>
    implements $ScanEventCopyWith<$Res> {
  factory $ScanEvent_ProgressCopyWith(
          ScanEvent_Progress value, $Res Function(ScanEvent_Progress) _then) =
      _$ScanEvent_ProgressCopyWithImpl;
  @useResult
  $Res call({ScanProgress field0});
}

/// @nodoc
class _$ScanEvent_ProgressCopyWithImpl<$Res>
    implements $ScanEvent_ProgressCopyWith<$Res> {
  _$ScanEvent_ProgressCopyWithImpl(this._self, this._then);

  final ScanEvent_Progress _self;
  final $Res Function(ScanEvent_Progress) _then;

  /// Create a copy of ScanEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(ScanEvent_Progress(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as ScanProgress,
    ));
  }
}

/// @nodoc

class ScanEvent_Done extends ScanEvent {
  const ScanEvent_Done(final List<DuplicateGroup> field0)
      : _field0 = field0,
        super._();

  final List<DuplicateGroup> _field0;
  @override
  List<DuplicateGroup> get field0 {
    if (_field0 is EqualUnmodifiableListView) return _field0;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_field0);
  }

  /// Create a copy of ScanEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $ScanEvent_DoneCopyWith<ScanEvent_Done> get copyWith =>
      _$ScanEvent_DoneCopyWithImpl<ScanEvent_Done>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is ScanEvent_Done &&
            const DeepCollectionEquality().equals(other._field0, _field0));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(_field0));

  @override
  String toString() {
    return 'ScanEvent.done(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $ScanEvent_DoneCopyWith<$Res>
    implements $ScanEventCopyWith<$Res> {
  factory $ScanEvent_DoneCopyWith(
          ScanEvent_Done value, $Res Function(ScanEvent_Done) _then) =
      _$ScanEvent_DoneCopyWithImpl;
  @useResult
  $Res call({List<DuplicateGroup> field0});
}

/// @nodoc
class _$ScanEvent_DoneCopyWithImpl<$Res>
    implements $ScanEvent_DoneCopyWith<$Res> {
  _$ScanEvent_DoneCopyWithImpl(this._self, this._then);

  final ScanEvent_Done _self;
  final $Res Function(ScanEvent_Done) _then;

  /// Create a copy of ScanEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(ScanEvent_Done(
      null == field0
          ? _self._field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as List<DuplicateGroup>,
    ));
  }
}

/// @nodoc
mixin _$SearchEvent {
  Object get field0;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SearchEvent &&
            const DeepCollectionEquality().equals(other.field0, field0));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, const DeepCollectionEquality().hash(field0));

  @override
  String toString() {
    return 'SearchEvent(field0: $field0)';
  }
}

/// @nodoc
class $SearchEventCopyWith<$Res> {
  $SearchEventCopyWith(SearchEvent _, $Res Function(SearchEvent) __);
}

/// Adds pattern-matching-related methods to [SearchEvent].
extension SearchEventPatterns on SearchEvent {
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
    TResult Function(SearchEvent_Hit value)? hit,
    TResult Function(SearchEvent_Done value)? done,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case SearchEvent_Hit() when hit != null:
        return hit(_that);
      case SearchEvent_Done() when done != null:
        return done(_that);
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
    required TResult Function(SearchEvent_Hit value) hit,
    required TResult Function(SearchEvent_Done value) done,
  }) {
    final _that = this;
    switch (_that) {
      case SearchEvent_Hit():
        return hit(_that);
      case SearchEvent_Done():
        return done(_that);
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
    TResult? Function(SearchEvent_Hit value)? hit,
    TResult? Function(SearchEvent_Done value)? done,
  }) {
    final _that = this;
    switch (_that) {
      case SearchEvent_Hit() when hit != null:
        return hit(_that);
      case SearchEvent_Done() when done != null:
        return done(_that);
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
    TResult Function(SearchHit field0)? hit,
    TResult Function(SearchSummary field0)? done,
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case SearchEvent_Hit() when hit != null:
        return hit(_that.field0);
      case SearchEvent_Done() when done != null:
        return done(_that.field0);
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
    required TResult Function(SearchHit field0) hit,
    required TResult Function(SearchSummary field0) done,
  }) {
    final _that = this;
    switch (_that) {
      case SearchEvent_Hit():
        return hit(_that.field0);
      case SearchEvent_Done():
        return done(_that.field0);
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
    TResult? Function(SearchHit field0)? hit,
    TResult? Function(SearchSummary field0)? done,
  }) {
    final _that = this;
    switch (_that) {
      case SearchEvent_Hit() when hit != null:
        return hit(_that.field0);
      case SearchEvent_Done() when done != null:
        return done(_that.field0);
      case _:
        return null;
    }
  }
}

/// @nodoc

class SearchEvent_Hit extends SearchEvent {
  const SearchEvent_Hit(this.field0) : super._();

  @override
  final SearchHit field0;

  /// Create a copy of SearchEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SearchEvent_HitCopyWith<SearchEvent_Hit> get copyWith =>
      _$SearchEvent_HitCopyWithImpl<SearchEvent_Hit>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SearchEvent_Hit &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'SearchEvent.hit(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $SearchEvent_HitCopyWith<$Res>
    implements $SearchEventCopyWith<$Res> {
  factory $SearchEvent_HitCopyWith(
          SearchEvent_Hit value, $Res Function(SearchEvent_Hit) _then) =
      _$SearchEvent_HitCopyWithImpl;
  @useResult
  $Res call({SearchHit field0});
}

/// @nodoc
class _$SearchEvent_HitCopyWithImpl<$Res>
    implements $SearchEvent_HitCopyWith<$Res> {
  _$SearchEvent_HitCopyWithImpl(this._self, this._then);

  final SearchEvent_Hit _self;
  final $Res Function(SearchEvent_Hit) _then;

  /// Create a copy of SearchEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(SearchEvent_Hit(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as SearchHit,
    ));
  }
}

/// @nodoc

class SearchEvent_Done extends SearchEvent {
  const SearchEvent_Done(this.field0) : super._();

  @override
  final SearchSummary field0;

  /// Create a copy of SearchEvent
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SearchEvent_DoneCopyWith<SearchEvent_Done> get copyWith =>
      _$SearchEvent_DoneCopyWithImpl<SearchEvent_Done>(this, _$identity);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SearchEvent_Done &&
            (identical(other.field0, field0) || other.field0 == field0));
  }

  @override
  int get hashCode => Object.hash(runtimeType, field0);

  @override
  String toString() {
    return 'SearchEvent.done(field0: $field0)';
  }
}

/// @nodoc
abstract mixin class $SearchEvent_DoneCopyWith<$Res>
    implements $SearchEventCopyWith<$Res> {
  factory $SearchEvent_DoneCopyWith(
          SearchEvent_Done value, $Res Function(SearchEvent_Done) _then) =
      _$SearchEvent_DoneCopyWithImpl;
  @useResult
  $Res call({SearchSummary field0});
}

/// @nodoc
class _$SearchEvent_DoneCopyWithImpl<$Res>
    implements $SearchEvent_DoneCopyWith<$Res> {
  _$SearchEvent_DoneCopyWithImpl(this._self, this._then);

  final SearchEvent_Done _self;
  final $Res Function(SearchEvent_Done) _then;

  /// Create a copy of SearchEvent
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  $Res call({
    Object? field0 = null,
  }) {
    return _then(SearchEvent_Done(
      null == field0
          ? _self.field0
          : field0 // ignore: cast_nullable_to_non_nullable
              as SearchSummary,
    ));
  }
}

// dart format on
