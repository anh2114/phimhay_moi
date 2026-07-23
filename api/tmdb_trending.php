<?php
/**
 * TMDB Trending API
 * - GET /api/tmdb_trending.php?window=day&limit=10
 * - Auto-fetch từ TMDB API, cache vào MySQL
 * - Auto-update nếu data > 6 giờ tuổi
 */

if (session_status() === PHP_SESSION_NONE) {
    session_start();
}
require_once dirname(__DIR__) . '/includes/config.php';

header('Content-Type: application/json; charset=utf-8');

// TMDB Config
define('TMDB_API_KEY', '768d65e151f19290118299b100da7a9b');
define('TMDB_BASE_URL', 'https://api.themoviedb.org/3');
define('TMDB_IMAGE_BASE', 'https://image.tmdb.org/t/p/w500');

$window = trim($_GET['window'] ?? 'day');
$limit = max(1, min(20, (int)($_GET['limit'] ?? 10)));

if (!in_array($window, ['day', 'week'])) {
    $window = 'day';
}

$db = getDB();

// Tạo bảng nếu chưa có
try {
    $db->exec("
        CREATE TABLE IF NOT EXISTS tmdb_trending (
            id INT AUTO_INCREMENT PRIMARY KEY,
            tmdb_id INT NOT NULL,
            title VARCHAR(255) NOT NULL,
            original_title VARCHAR(255),
            overview TEXT,
            poster_path VARCHAR(255),
            backdrop_path VARCHAR(255),
            vote_average DECIMAL(3,1) DEFAULT 0,
            vote_count INT DEFAULT 0,
            release_date VARCHAR(20),
            genre_ids VARCHAR(255),
            popularity DECIMAL(10,3) DEFAULT 0,
            trending_window ENUM('day','week') NOT NULL,
            fetched_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE KEY unique_trending (tmdb_id, trending_window),
            INDEX idx_window_fetched (trending_window, fetched_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    ");
} catch (Exception $e) {
    // Table might already exist
}

// Kiểm tra data có cần refresh không (older than 6 hours)
$needsRefresh = true;
try {
    $stmt = $db->prepare("
        SELECT MAX(fetched_at) as last_fetch 
        FROM tmdb_trending 
        WHERE trending_window = ?
    ");
    $stmt->execute([$window]);
    $row = $stmt->fetch();
    if ($row && $row['last_fetch']) {
        $lastFetch = strtotime($row['last_fetch']);
        $needsRefresh = (time() - $lastFetch) > 21600; // 6 hours
    }
} catch (Exception $e) {
    $needsRefresh = true;
}

// Fetch từ TMDB nếu cần refresh
if ($needsRefresh) {
    try {
        $url = TMDB_BASE_URL . "/trending/movie/{$window}?api_key=" . TMDB_API_KEY;
        $ch = curl_init($url);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_TIMEOUT, 10);
        curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, false);
        $response = curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);

        if ($httpCode === 200 && $response) {
            $data = json_decode($response, true);
            if (isset($data['results']) && is_array($data['results'])) {
                // Xóa data cũ
                $db->prepare("DELETE FROM tmdb_trending WHERE trending_window = ?")->execute([$window]);

                // Insert data mới
                $stmt = $db->prepare("
                    INSERT INTO tmdb_trending 
                    (tmdb_id, title, original_title, overview, poster_path, backdrop_path, 
                     vote_average, vote_count, release_date, genre_ids, popularity, trending_window, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NOW())
                    ON DUPLICATE KEY UPDATE
                    title = VALUES(title), vote_average = VALUES(vote_average), 
                    popularity = VALUES(popularity), fetched_at = NOW()
                ");

                foreach ($data['results'] as $movie) {
                    $stmt->execute([
                        $movie['id'] ?? 0,
                        $movie['title'] ?? '',
                        $movie['original_title'] ?? '',
                        $movie['overview'] ?? '',
                        $movie['poster_path'] ?? '',
                        $movie['backdrop_path'] ?? '',
                        $movie['vote_average'] ?? 0,
                        $movie['vote_count'] ?? 0,
                        $movie['release_date'] ?? '',
                        implode(',', $movie['genre_ids'] ?? []),
                        $movie['popularity'] ?? 0,
                        $window,
                    ]);
                }
            }
        }
    } catch (Exception $e) {
        // Silent fail — dùng data cũ
    }
}

// Lấy data từ database
try {
    $stmt = $db->prepare("
        SELECT tmdb_id as id, title, original_title, overview, poster_path, backdrop_path,
               vote_average, vote_count, release_date, genre_ids, popularity
        FROM tmdb_trending 
        WHERE trending_window = ?
        ORDER BY popularity DESC
        LIMIT ?
    ");
    $stmt->execute([$window, $limit]);
    $results = $stmt->fetchAll(PDO::FETCH_ASSOC);

    echo json_encode([
        'success' => true,
        'window' => $window,
        'count' => count($results),
        'results' => $results,
    ]);
} catch (Exception $e) {
    echo json_encode([
        'success' => false,
        'error' => 'Database error',
    ]);
}
