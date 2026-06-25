import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:phimhay_app/config/app_config.dart';
import 'package:phimhay_app/config/theme.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';

class ActorsListScreen extends StatefulWidget {
  const ActorsListScreen({super.key});

  @override
  State<ActorsListScreen> createState() => _ActorsListScreenState();
}

class _ActorsListScreenState extends State<ActorsListScreen> {
  final Dio _dio = Dio();
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _debounce;

  List<dynamic> _actors = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String? _error;
  int _total = 0;
  int _currentPage = 1;
  bool _hasMore = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _fetchActors();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _fetchActors({bool loadMore = false}) async {
    if (_isLoading) return;
    if (loadMore && (_isLoadingMore || !_hasMore)) return;

    setState(() {
      if (loadMore) _isLoadingMore = true;
      else { _isLoading = true; _error = null; }
    });

    try {
      final params = <String, dynamic>{
        'list': '1',
        'page': loadMore ? _currentPage + 1 : 1,
        'per_page': 50,
      };
      if (_searchQuery.isNotEmpty) params['q'] = _searchQuery;

      final res = await _dio.get('${AppConfig.apiUrl}/actor.php', queryParameters: params);
      final raw = res.data;
      final data = raw is String ? Map<String, dynamic>.from(jsonDecode(raw)) : raw as Map<String, dynamic>;

      if (data['success'] == true) {
        final actors = data['actors'] as List<dynamic>? ?? [];
        final total = data['total'] ?? 0;
        if (!mounted) return;
        setState(() {
          if (loadMore) {
            _actors.addAll(actors);
            _currentPage++;
          } else {
            _actors = actors;
            _currentPage = 1;
          }
          _total = total;
          _hasMore = _actors.length < total;
          _isLoading = false;
          _isLoadingMore = false;
        });
      } else {
        if (!mounted) return;
        setState(() { _error = data['message'] ?? 'Khong the tai danh sach dien vien'; _isLoading = false; _isLoadingMore = false; });
      }
    } on DioException catch (_) {
      if (!mounted) return;
      setState(() { _error = 'Loi ket noi. Kiem tra mang va thu lai.'; _isLoading = false; _isLoadingMore = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Co loi xay ra'; _isLoading = false; _isLoadingMore = false; });
    }
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    setState(() => _searchQuery = query);
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _currentPage = 1;
      _hasMore = true;
      _fetchActors();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('Dien vien (${_total > 0 ? _total : ""})', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              decoration: BoxDecoration(color: AppTheme.bgCard, borderRadius: BorderRadius.circular(12)),
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                onChanged: _onSearchChanged,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Tim dien vien...',
                  hintStyle: TextStyle(color: AppTheme.textMuted),
                  prefixIcon: Icon(Icons.search_rounded, color: AppTheme.textMuted, size: 20),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(icon: Icon(Icons.clear_rounded, color: AppTheme.textMuted, size: 18), onPressed: () { _searchController.clear(); _onSearchChanged(''); })
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? _buildSkeleton()
                : _error != null
                    ? _buildError()
                    : _actors.isEmpty
                        ? Center(child: Text(_searchQuery.isNotEmpty ? 'Khong tim thay dien vien' : 'Chua co dien vien', style: TextStyle(color: AppTheme.textMuted, fontSize: 14)))
                        : _buildList(),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _actors.length + (_hasMore ? 1 : 0),
      itemBuilder: (ctx, i) {
        if (i == _actors.length) {
          _fetchActors(loadMore: true);
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(color: AppTheme.gold, strokeWidth: 2)),
          );
        }
        final actor = _actors[i];
        final nameVi = actor['name_vi'] ?? actor['name'] ?? '';
        final nameEn = actor['name'] ?? '';
        final photo = actor['photo_url'] ?? '';
        final gender = actor['gender'] ?? '';

        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
            leading: ClipOval(
              child: CachedNetworkImage(
                imageUrl: photo,
                width: 50,
                height: 50,
                fit: BoxFit.cover,
                placeholder: (_, __) => Container(width: 50, height: 50, color: AppTheme.bgCard),
                errorWidget: (_, __, ___) => Container(
                  width: 50, height: 50, color: AppTheme.bgCard,
                  child: Icon(Icons.person, color: AppTheme.textMuted),
                ),
              ),
            ),
            title: Text(nameVi, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
            subtitle: Row(
              children: [
                if (nameEn.isNotEmpty && nameEn != nameVi)
                  Expanded(child: Text(nameEn, style: TextStyle(color: AppTheme.textMuted, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (gender.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: AppTheme.gold.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4)),
                    child: Text(gender, style: TextStyle(color: AppTheme.gold, fontSize: 10, fontWeight: FontWeight.w600)),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSkeleton() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: 12,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(vertical: 4),
          leading: Container(width: 50, height: 50, decoration: BoxDecoration(color: AppTheme.bgCard, shape: BoxShape.circle)),
          title: Container(height: 14, width: 120, color: AppTheme.bgCard),
          subtitle: Container(height: 10, width: 80, color: AppTheme.bgCard),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: AppTheme.textMuted.withValues(alpha: 0.5)),
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: AppTheme.textSub, fontSize: 14)),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: _fetchActors,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(color: AppTheme.gold, borderRadius: BorderRadius.circular(8)),
              child: const Text('Thu lai', style: TextStyle(color: Color(0xFF1A1100), fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}
