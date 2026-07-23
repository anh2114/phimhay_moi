class AppConfig {
  static String get baseUrl => 'https://xiaofilm.online';
  static String get apiUrl  => 'https://xiaofilm.online/api';
  static const int connectTimeout = 15000;
  static const int receiveTimeout = 15000;

  // TMDB API
  static const String tmdbApiKey = '768d65e151f19290118299b100da7a9b';
  static const String tmdbBaseUrl = 'https://api.themoviedb.org/3';
  static const String tmdbImageBase = 'https://image.tmdb.org/t/p/w500';

  static String proxyHlsUrl(String url) {
    return '$apiUrl/hls_proxy.php?url=${Uri.encodeComponent(url)}';
  }

  static String proxyHlsFullUrl(String url) {
    return '$apiUrl/hls_proxy.php?url=${Uri.encodeComponent(url)}&full=1';
  }

  /// M3U8 proxy — strip ad segments before player
  static String proxyM3u8Url(String url) {
    return '$apiUrl/proxy_m3u8.php?url=${Uri.encodeComponent(url)}';
  }

  static String get serverHealthUrl => '$apiUrl/server_health.php';
}
