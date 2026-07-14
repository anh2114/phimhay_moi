import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:phimhay_app/config/app_config.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:phimhay_app/screens/movie_detail/movie_detail_screen.dart';
import 'package:phimhay_app/services/image_cache_manager.dart';

class ActorDetailScreen extends StatefulWidget {
  final String? name;
  final int? tmdbId;

  const ActorDetailScreen({super.key, this.name, this.tmdbId});

  @override
  State<ActorDetailScreen> createState() => _ActorDetailScreenState();
}

class _ActorDetailScreenState extends State<ActorDetailScreen> {
  final Dio _dio = Dio();
  bool _isLoading = true;
  String? _error;
  Map<String, dynamic>? _actor;
  List<dynamic> _movies = [];
  bool _bioExpanded = false;
  int _filterIndex = 0;

  @override
  void initState() {
    super.initState();
    _fetchActor();
  }

  @override
  void dispose() {
    _dio.close(force: true);
    super.dispose();
  }

  Future<void> _fetchActor() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final params = <String, dynamic>{};
      if (widget.tmdbId != null && widget.tmdbId! > 0) {
        params['tmdb_id'] = widget.tmdbId;
      } else if (widget.name != null && widget.name!.isNotEmpty) {
        params['name'] = widget.name;
      } else {
        setState(() { _error = 'Thieu thong tin dien vien'; _isLoading = false; });
        return;
      }

      final res = await _dio.get('${AppConfig.apiUrl}/actor_detail.php', queryParameters: params);
      final data = res.data is String ? jsonDecode(res.data) : res.data;

      if (!mounted) return;
      if (data['success'] == true) {
        setState(() {
          _actor = data['actor'];
          _movies = (data['movies'] ?? data['actor']?['movies'] ?? []) as List<dynamic>;
          _isLoading = false;
        });
      } else {
        setState(() { _error = data['message'] ?? 'Khong tim thay dien vien'; _isLoading = false; });
      }
    } on DioException catch (_) {
      if (!mounted) return;
      setState(() { _error = 'Loi ket noi'; _isLoading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Co loi xay ra'; _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: _isLoading
          ? _buildLoading()
          : _error != null
              ? _buildError()
              : _buildContent(),
    );
  }

  Widget _buildLoading() {
    return Column(
      children: [
        SizedBox(height: MediaQuery.of(context).padding.top + 56, child: _buildNavBar('')),
        Expanded(child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(child: Container(width: 160, height: 200, decoration: BoxDecoration(color: AppTheme.bgCard, borderRadius: BorderRadius.circular(20)))),
            const SizedBox(height: 16),
            Center(child: Container(width: 140, height: 18, color: AppTheme.bgCard)),
            const SizedBox(height: 8),
            Center(child: Container(width: 100, height: 14, color: AppTheme.bgCard)),
            const SizedBox(height: 24),
            ...List.generate(6, (_) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(children: [
                Container(width: (MediaQuery.of(context).size.width - 44) / 3, height: ((MediaQuery.of(context).size.width - 44) / 3) * 1.5, decoration: BoxDecoration(color: AppTheme.bgCard, borderRadius: BorderRadius.circular(10))),
                const SizedBox(width: 12),
                Container(width: (MediaQuery.of(context).size.width - 44) / 3, height: ((MediaQuery.of(context).size.width - 44) / 3) * 1.5, decoration: BoxDecoration(color: AppTheme.bgCard, borderRadius: BorderRadius.circular(10))),
                const SizedBox(width: 12),
                Container(width: (MediaQuery.of(context).size.width - 44) / 3, height: ((MediaQuery.of(context).size.width - 44) / 3) * 1.5, decoration: BoxDecoration(color: AppTheme.bgCard, borderRadius: BorderRadius.circular(10))),
              ]),
            )),
          ],
        )),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      children: [
        SizedBox(height: MediaQuery.of(context).padding.top + 56, child: _buildNavBar('')),
        Expanded(child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, size: 48, color: AppTheme.textMuted),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: AppTheme.textSub, fontSize: 14)),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _fetchActor,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(color: AppTheme.gold, borderRadius: BorderRadius.circular(8)),
                child: const Text('Thu lai', style: TextStyle(color: Color(0xFF1A1100), fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        )),
      ],
    );
  }

  Widget _buildContent() {
    final actor = _actor!;
    final name = actor['name'] ?? widget.name ?? '';
    final alsoKnown = (actor['also_known'] as List<dynamic>?) ?? [];
    final gender = actor['gender'] ?? '';
    final birthday = actor['birthday'] ?? '';
    final deathday = actor['deathday'] ?? '';
    final place = actor['place'] ?? '';
    final bio = actor['biography'] ?? '';
    final photo = actor['photo'] ?? '';

    final filteredMovies = _filterMovies();

    return Column(
      children: [
        SizedBox(
          height: MediaQuery.of(context).padding.top + 56,
          child: _buildNavBar(name),
        ),
        Expanded(child: RefreshIndicator(
          onRefresh: _fetchActor,
          color: AppTheme.gold,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              SliverToBoxAdapter(child: _buildHero(photo, name, alsoKnown, gender, birthday, deathday, place, bio)),
              SliverToBoxAdapter(child: _buildMoviesSection(filteredMovies)),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ),
        )),
      ],
    );
  }

  Widget _buildNavBar(String name) {
    return Container(
      color: AppTheme.bg,
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
      child: Row(
        children: [
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(child: Text(
            name,
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700),
            maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
          )),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _buildHero(String photo, String name, List<dynamic> alsoKnown, String gender, String birthday, String deathday, String place, String bio) {
    return Column(
      children: [
        const SizedBox(height: 12),
        // Photo
        Container(
          width: 160, height: 200,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.6), blurRadius: 24, offset: const Offset(0, 12))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: photo.isNotEmpty
                ? CachedNetworkImage(
                    imageUrl: photo,
                    fit: BoxFit.cover,
                    cacheManager: AppImageCacheManager(),
                    fadeInDuration: const Duration(milliseconds: 200),
                    fadeOutDuration: const Duration(milliseconds: 100),
                    placeholder: (_, __) => Container(color: AppTheme.bgCard),
                    errorWidget: (_, __, ___) => Container(color: AppTheme.bgCard, child: const Icon(Icons.person, color: AppTheme.textMuted, size: 64)),
                  )
                : Container(color: AppTheme.bgCard, child: const Icon(Icons.person, color: AppTheme.textMuted, size: 64)),
          ),
        ),
        const SizedBox(height: 16),
        // Name
        Text(name, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800), textAlign: TextAlign.center),
        // Name (EN) from also_known if different
        if (alsoKnown.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              alsoKnown.firstWhere((n) => n != name, orElse: () => ''),
              style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
              textAlign: TextAlign.center,
            ),
          ),
        // Also Known As tags
        if (alsoKnown.length > 1) ...[
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Wrap(
              spacing: 6, runSpacing: 6, alignment: WrapAlignment.center,
              children: alsoKnown.take(5).map((n) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppTheme.border),
                  color: Colors.white.withValues(alpha: 0.04),
                ),
                child: Text(n, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.textSub)),
              )).toList(),
            ),
          ),
        ],
        // Meta
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(children: [
            if (gender.isNotEmpty) _metaRow('Gioi tinh', Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(color: AppTheme.accentDim, borderRadius: BorderRadius.circular(6)),
                  child: Text(gender, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.gold)),
                ),
              ],
            )),
            if (birthday.isNotEmpty) _metaRow('Ngay sinh', Text(birthday + (deathday.isNotEmpty ? ' — $deathday' : ''), style: const TextStyle(fontSize: 13, color: AppTheme.textSub))),
            if (place.isNotEmpty) _metaRow('Noi sinh', Text(place, style: const TextStyle(fontSize: 13, color: AppTheme.textSub))),
          ]),
        ),
        // Bio
        if (bio.isNotEmpty) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Gioi thieu', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.textMuted)),
                const SizedBox(height: 6),
                AnimatedCrossFade(
                  firstChild: Text(bio, style: const TextStyle(fontSize: 13, color: AppTheme.textSub, height: 1.75), maxLines: 4, overflow: TextOverflow.ellipsis),
                  secondChild: Text(bio, style: const TextStyle(fontSize: 13, color: AppTheme.textSub, height: 1.75)),
                  crossFadeState: _bioExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 200),
                ),
                GestureDetector(
                  onTap: () => setState(() => _bioExpanded = !_bioExpanded),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(_bioExpanded ? 'Thu gon' : 'Xem them', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.gold)),
                      const SizedBox(width: 4),
                      Icon(_bioExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 16, color: AppTheme.gold),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _metaRow(String label, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        SizedBox(width: 72, child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textMuted))),
        child,
      ]),
    );
  }

  List<dynamic> _filterMovies() {
    if (_filterIndex == 0) return _movies;
    String targetType = _filterIndex == 1 ? 'series' : 'single';
    return _movies.where((m) {
      final t = m['db_type'] ?? m['type'] ?? m['media_type'] ?? '';
      return t == targetType;
    }).toList();
  }

  Widget _buildMoviesSection(List<dynamic> movies) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Expanded(child: Text('Phim da tham gia', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(color: AppTheme.accentDim, borderRadius: BorderRadius.circular(8)),
                child: Text('${movies.length} phim', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.gold)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Filter tabs
          Row(
            children: [
              _filterTab('Tat ca', 0),
              const SizedBox(width: 8),
              _filterTab('Phim bo', 1),
              const SizedBox(width: 8),
              _filterTab('Phim le', 2),
            ],
          ),
          const SizedBox(height: 16),
          // Grid
          if (movies.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(child: Text('Chua co phim nao', style: TextStyle(color: AppTheme.textMuted, fontSize: 14))),
            )
          else
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 0.52,
              ),
              itemCount: movies.length,
              itemBuilder: (_, i) => _actorMovieCard(movies[i]),
            ),
        ],
      ),
    );
  }

  Widget _filterTab(String label, int index) {
    final active = _filterIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _filterIndex = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          color: active ? AppTheme.textPrimary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? AppTheme.textPrimary : AppTheme.border, width: 1.5),
        ),
        child: Text(label, style: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w700,
          color: active ? AppTheme.bg : AppTheme.textMuted,
        )),
      ),
    );
  }

  Widget _actorMovieCard(dynamic movie) {
    final inDb = movie['_in_db'] == true || movie['db_slug'] != null;
    final title = inDb ? (movie['db_name'] ?? movie['title'] ?? '') : (movie['title'] ?? '');
    final original = inDb ? (movie['db_origin'] ?? movie['original'] ?? '') : (movie['original'] ?? '');
    final poster = movie['thumb_url'] ?? movie['db_thumb'] ?? movie['poster'] ?? '';
    final year = (inDb ? (movie['db_year'] ?? '') : (movie['year'] ?? '')).toString();
    final rating = ((inDb ? (movie['db_tmdb_rating'] ?? movie['db_imdb'] ?? 0) : (movie['rating'] ?? 0))).toDouble();
    final epCur = inDb ? (movie['db_ep_cur'] ?? '') : '';
    final epTotal = inDb ? (movie['db_ep_total'] ?? '') : '';
    final quality = inDb ? (movie['db_quality'] ?? '') : '';
    final slug = movie['db_slug'] ?? movie['slug'] ?? '';
    final dbId = movie['id'] ?? 0;

    return GestureDetector(
      onTap: () {
        if (inDb && slug.isNotEmpty) {
          Navigator.push(context, MaterialPageRoute(
            builder: (_) => MovieDetailScreen(movieId: dbId is int ? dbId : 0, slug: slug),
          ));
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Poster
          Expanded(flex: 5, child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: AppTheme.bgCard,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  poster.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: poster,
                          fit: BoxFit.cover,
                          cacheManager: AppImageCacheManager(),
                          fadeInDuration: const Duration(milliseconds: 200),
                          fadeOutDuration: const Duration(milliseconds: 100),
                          placeholder: (_, __) => Container(color: AppTheme.bgCard),
                          errorWidget: (_, __, ___) => Container(color: AppTheme.bgCard, child: const Icon(Icons.movie_outlined, color: AppTheme.textMuted, size: 28)),
                        )
                      : Container(color: AppTheme.bgCard, child: const Icon(Icons.movie_outlined, color: AppTheme.textMuted, size: 28)),
                  // Badges
                  if (epCur.toString().isNotEmpty)
                    Positioned(
                      bottom: 6, left: 6,
                      child: Wrap(spacing: 3, runSpacing: 3, children: [
                        _smallBadge(_formatEpCur(epCur.toString()), const Color(0xD1121218), const Color(0xFFF1F5F9), border: const Color(0x14FFFFFF)),
                      ]),
                    ),
                  // Rating
                  if (rating > 0)
                    Positioned(
                      top: 6, right: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.7), borderRadius: BorderRadius.circular(4)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.star_rounded, size: 10, color: AppTheme.gold),
                          const SizedBox(width: 2),
                          Text(rating.toStringAsFixed(1), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppTheme.gold)),
                        ]),
                      ),
                    ),
                ],
              ),
            ),
          )),
          const SizedBox(height: 6),
          // Title
          Expanded(flex: 2, child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppTheme.textPrimary, height: 1.3)),
              if (original.isNotEmpty && original != title)
                Text(original, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: AppTheme.textMuted)),
            ],
          )),
        ],
      ),
    );
  }

  Widget _smallBadge(String label, Color bg, Color text, {Color? border}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: border != null ? Border.all(color: border, width: 1) : null,
      ),
      child: Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: text)),
    );
  }

  String _formatEpCur(String ep) {
    final match = RegExp(r'(\d+)').allMatches(ep);
    if (match.isEmpty) return ep;
    final num = match.last.group(0);
    return 'PD. $num';
  }
}
