<?php
define('INCLUDED', true);
require_once dirname(__DIR__) . '/includes/config.php';

header('Content-Type: application/json; charset=utf-8');

$actorName = trim($_GET['name'] ?? '');
$tmdbId = (int)($_GET['tmdb_id'] ?? 0);
$syncAll = !empty($_GET['sync']);

if (!$actorName && !$tmdbId) {
    echo json_encode(['success' => false, 'error' => 'Thiếu tên hoặc tmdb_id']);
    exit;
}

$db = getDB();

if (!$tmdbId && $actorName) {
    $sLookup = $db->prepare("SELECT tmdb_id FROM actors WHERE name = ? OR name_vi = ? OR JSON_SEARCH(also_known_as, 'one', ?) IS NOT NULL LIMIT 1");
    $sLookup->execute([$actorName, $actorName, $actorName]);
    $rLookup = $sLookup->fetch();
    if ($rLookup && (int)$rLookup['tmdb_id'] > 0) {
        $tmdbId = (int)$rLookup['tmdb_id'];
    }
}

function afFetch(string $url): ?string {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 15,
        CURLOPT_SSL_VERIFYPEER => false,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_USERAGENT => 'PhimHay/1.0 (actor-filmography)',
    ]);
    $res = curl_exec($ch);
    curl_close($ch);
    return $res ?: null;
}

function afNormalizeTitle(string $s): string {
    $s = mb_strtolower(trim($s));
    $from = ['à','á','ả','ã','ạ','ă','ắ','ặ','ằ','ẳ','ẵ','â','ấ','ầ','ẩ','ẫ','ậ',
             'đ','è','é','ẻ','ẽ','ẹ','ê','ế','ề','ể','ễ','ệ',
             'ì','í','ỉ','ĩ','ị','ò','ó','ỏ','õ','ọ','ô','ố','ồ','ổ','ỗ','ộ',
             'ơ','ớ','ờ','ở','ỡ','ợ','ù','ú','ủ','ũ','ụ','ư','ứ','ừ','ử','ữ','ự',
             'ỳ','ý','ỷ','ỹ','ỵ'];
    $to   = ['a','a','a','a','a','a','a','a','a','a','a','a','a','a','a','a','a',
             'd','e','e','e','e','e','e','e','e','e','e','e',
             'i','i','i','i','i','o','o','o','o','o','o','o','o','o','o','o',
             'o','o','o','o','o','o','u','u','u','u','u','u','u','u','u','u','u',
             'y','y','y','y','y'];
    $s = str_replace($from, $to, $s);
    $s = preg_replace('/[^\p{L}\p{N}\s]/u', ' ', $s);
    return preg_replace('/\s+/', ' ', trim($s));
}

function afTitleMatches(string $apiName, string $apiOrigin, string $queryNorm): bool {
    $n = afNormalizeTitle($apiName);
    $o = afNormalizeTitle($apiOrigin);
    if ($n === $queryNorm || $o === $queryNorm) return true;
    if (mb_strlen($queryNorm) >= 4) {
        if (mb_strpos($n, $queryNorm) !== false) return true;
        if (mb_strpos($o, $queryNorm) !== false) return true;
    }
    return false;
}

function afSyncSingleMovie(PDO $db, string $name): array {
    $sources = [
        'ophim'  => OPHIM_API,
        'kkphim' => KKPHIM_API,
        'nguonc' => NGUONC_API,
    ];
    $queryNorm = afNormalizeTitle($name);

    foreach ($sources as $src => $baseUrl) {
        $searchData = afFetch("{$baseUrl}/v1/api/tim-kiem?keyword=" . rawurlencode($name) . "&limit=10");
        if (!$searchData) continue;
        $data = json_decode($searchData, true);
        if (!$data) continue;
        $items = $data['data']['items'] ?? $data['items'] ?? [];
        if (empty($items)) continue;

        $bestSlug = null;
        foreach ($items as $item) {
            if (afTitleMatches($item['name'] ?? '', $item['origin_name'] ?? '', $queryNorm)) {
                $bestSlug = $item['slug'] ?? '';
                break;
            }
        }
        if (!$bestSlug && count($items) === 1) {
            $bestSlug = $items[0]['slug'] ?? '';
        }
        if (!$bestSlug) continue;

        usleep(300000);
        $detailRaw = afFetch("{$baseUrl}/phim/{$bestSlug}");
        if (!$detailRaw) continue;
        $detail = json_decode($detailRaw, true);
        if (!$detail || empty($detail['movie'])) continue;

        $m = $detail['movie'];
        $apiModified = $m['modified']['time'] ?? null;

        $stmt = $db->prepare("SELECT id FROM movies WHERE slug = ? LIMIT 1");
        $stmt->execute([$bestSlug]);
        $row = $stmt->fetch();

        if ($row) {
            $movieId = (int)$row['id'];
            $episodes = $detail['episodes'] ?? [];
            $epCurrent = $m['episode_current'] ?? '';
            $epTotal = $m['episode_total'] ?? '';
            $epStr = '';
            if (!empty($episodes)) {
                foreach ($episodes as $epGroup) {
                    $epName = $epGroup['name'] ?? '';
                    $serverEpisodes = $epGroup['server_data'] ?? [];
                    if (!empty($serverEpisodes)) {
                        $lastEp = end($serverEpisodes);
                        $epStr = $lastEp['name'] ?? $epName;
                    }
                }
            }
            $db->prepare("UPDATE movies SET episode_current=?, episode_total=?, api_modified=?, source_api=? WHERE id=?")
               ->execute([$epCurrent ?: $epStr, $epTotal, $apiModified, $src, $movieId]);
            return ['success' => true, 'slug' => $bestSlug, 'movie_id' => $movieId, 'action' => 'updated'];
        }

        $actorStr = is_array($m['actor'] ?? null) ? implode(', ', $m['actor']) : ($m['actor'] ?? '');
        $directorStr = is_array($m['director'] ?? null) ? implode(', ', $m['director']) : ($m['director'] ?? '');

        $posterUrl = $m['poster_url'] ?? '';
        $thumbUrl = $m['thumb_url'] ?? '';
        if ($posterUrl && !str_starts_with($posterUrl, 'http')) $posterUrl = ($src === 'ophim' ? 'https://ophim1.com' : 'https://phimapi.com') . $posterUrl;
        if ($thumbUrl && !str_starts_with($thumbUrl, 'http')) $thumbUrl = ($src === 'ophim' ? 'https://ophim1.com' : 'https://phimapi.com') . $thumbUrl;

        $db->prepare("INSERT INTO movies (slug,name,origin_name,thumb_url,poster_url,trailer_url,year,type,status,
                       quality,lang,episode_current,episode_total,time,description,director,actor,source_api,api_modified,tmdb_id,
                       created_at, updated_at)
                      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NOW(),NOW())")
           ->execute([
               $bestSlug,
               $m['name'] ?? '',
               $m['origin_name'] ?? '',
               $thumbUrl,
               $posterUrl,
               $m['trailer_url'] ?? '',
               $m['year'] ?? '',
               $m['type'] ?? 'single',
               $m['status'] ?? '',
               $m['quality'] ?? 'HD',
               $m['lang'] ?? 'Vietsub',
               $m['episode_current'] ?? '',
               $m['episode_total'] ?? '',
               $m['time'] ?? '',
               strip_tags($m['content'] ?? ''),
               $directorStr,
               $actorStr,
               $src,
               $apiModified,
               $m['tmdb_id'] ?? 0,
           ]);
        $newId = (int)$db->lastInsertId();

        foreach ($m['category'] ?? [] as $cat) {
            $catName = $cat['name'] ?? '';
            $catSlug = $cat['slug'] ?? '';
            if ($catName && $catSlug) {
                $gs = $db->prepare("SELECT id FROM genres WHERE slug=?");
                $gs->execute([$catSlug]);
                $gg = $gs->fetch();
                $gid = $gg ? (int)$gg['id'] : null;
                if (!$gid) {
                    $db->prepare("INSERT INTO genres (name,slug) VALUES (?,?)")->execute([$catName, $catSlug]);
                    $gid = (int)$db->lastInsertId();
                }
                if ($gid) $db->prepare("INSERT IGNORE INTO movie_genres VALUES (?,?)")->execute([$newId, $gid]);
            }
        }

        foreach ($m['country'] ?? [] as $c) {
            $cName = $c['name'] ?? '';
            $cSlug = $c['slug'] ?? '';
            if ($cName && $cSlug) {
                $cs = $db->prepare("SELECT id FROM countries WHERE slug=?");
                $cs->execute([$cSlug]);
                $cg = $cs->fetch();
                $cid = $cg ? (int)$cg['id'] : null;
                if (!$cid) {
                    $db->prepare("INSERT INTO countries (name,slug) VALUES (?,?)")->execute([$cName, $cSlug]);
                    $cid = (int)$db->lastInsertId();
                }
                if ($cid) $db->prepare("INSERT IGNORE INTO movie_countries VALUES (?,?)")->execute([$newId, $cid]);
            }
        }

        $order = 0;
        $epStmt = $db->prepare("INSERT INTO episodes (movie_id,server_name,source,ep_name,ep_slug,link_embed,link_m3u8,sort_order) VALUES (?,?,?,?,?,?,?,?)");
        foreach ($detail['episodes'] ?? [] as $server) {
            $sName = $server['server_name'] ?? 'Mặc định';
            foreach ($server['server_data'] ?? [] as $ep) {
                $epStmt->execute([$newId, $sName, $src ?? 'ophim', $ep['name'] ?? '', $ep['slug'] ?? '', $ep['link_embed'] ?? $ep['embed'] ?? '', $ep['link_m3u8'] ?? '', $order++]);
            }
        }

        return ['success' => true, 'slug' => $bestSlug, 'movie_id' => $newId, 'action' => 'created'];
    }

    return ['success' => false, 'message' => 'Không tìm thấy phim "' . $name . '"'];
}

function afExtractFilmographySection(string $wikitext): string {
    $tvSubHeaders = '/(?:===+\s*(?:Phim.truyền.hình|Truyền.hình|Television.series|TV.series|Phim.truyen.hinh|Television).*)/iu';
    if (preg_match_all($tvSubHeaders, $wikitext, $tvSub, PREG_OFFSET_CAPTURE)) {
        $lastStart = $tvSub[0][count($tvSub[0]) - 1][1];
        $startLen = strlen($tvSub[0][count($tvSub[0]) - 1][0]);
        $afterSection = substr($wikitext, $lastStart + $startLen);
        $nextSection = preg_match('/\n==[^=]/', $afterSection, $nm, PREG_OFFSET_CAPTURE);
        if ($nextSection) {
            return substr($wikitext, $lastStart, $startLen + $nm[0][1]);
        }
        return substr($wikitext, $lastStart);
    }

    $tvSections = '/(?:==+\s*(?:Phim.truyền.hình|Truyền.hình|Television|TV.series|Phim.truyen.hinh).*)/iu';
    if (preg_match_all($tvSections, $wikitext, $tvMatches, PREG_OFFSET_CAPTURE)) {
        $lastStart = $tvMatches[0][count($tvMatches[0]) - 1][1];
        $startLen = strlen($tvMatches[0][count($tvMatches[0]) - 1][0]);
        $afterSection = substr($wikitext, $lastStart + $startLen);
        $nextSection = preg_match('/\n==[^=]/', $afterSection, $nm, PREG_OFFSET_CAPTURE);
        if ($nextSection) {
            return substr($wikitext, $lastStart, $startLen + $nm[0][1]);
        }
        return substr($wikitext, $lastStart);
    }

    $filmSections = '/(?:==+\s*(?:Danh.sách.phim|Phim.đã.tham.gia|Filmography|Films?|Selected.filmography|Selected.works|Partial.filmography|Other.works|Danh.sách).*)/iu';
    if (preg_match_all($filmSections, $wikitext, $matches, PREG_OFFSET_CAPTURE)) {
        $lastStart = $matches[0][count($matches[0]) - 1][1];
        $startLen = strlen($matches[0][count($matches[0]) - 1][0]);
        $afterSection = substr($wikitext, $lastStart + $startLen);
        $nextSection = preg_match('/\n==[^=]/', $afterSection, $nm, PREG_OFFSET_CAPTURE);
        if ($nextSection) {
            return substr($wikitext, $lastStart, $startLen + $nm[0][1]);
        }
        return substr($wikitext, $lastStart);
    }
    return $wikitext;
}

function afParseFilmographyFromWikitext(string $wikitext): array {
    $filmSection = afExtractFilmographySection($wikitext);
    $titles = [];

    preg_match_all('/!\s*scope="row"\s*\|\s*(.+)/i', $filmSection, $rows);
    foreach ($rows[1] as $row) {
        $row = trim($row);

        if (preg_match_all('/\[\[([^\]|]+?)(?:\|([^\]]+))?\]\]/', $row, $links)) {
            foreach ($links[2] as $display) {
                $t = trim($display);
                if ($t !== '' && mb_strlen($t) >= 2) $titles[] = $t;
            }
            foreach ($links[1] as $i => $linkTitle) {
                if (empty($links[2][$i]) || trim($links[2][$i]) === '') {
                    $t = trim($linkTitle);
                    if ($t !== '' && mb_strlen($t) >= 2) $titles[] = $t;
                }
            }
        } elseif (preg_match_all('/{{sort\|[^|]+\|\[\[([^\]|]+?)(?:\|([^\]]+))?\]\]/', $row, $sortLinks)) {
            foreach ($sortLinks[2] as $display) {
                $t = trim($display);
                if ($t !== '' && mb_strlen($t) >= 2) $titles[] = $t;
            }
            foreach ($sortLinks[1] as $i => $linkTitle) {
                if (empty($sortLinks[2][$i]) || trim($sortLinks[2][$i]) === '') {
                    $t = trim($linkTitle);
                    if ($t !== '' && mb_strlen($t) >= 2) $titles[] = $t;
                }
            }
        } else {
            $cleaned = preg_replace('/\'{2,}/', '', $row);
            $cleaned = preg_replace('/{{[^}]+}}/', '', $cleaned);
            $cleaned = trim($cleaned);
            if ($cleaned !== '' && mb_strlen($cleaned) >= 3 && mb_strlen($cleaned) <= 120) {
                $titles[] = $cleaned;
            }
        }
    }

    if (empty($titles)) {
        $tableRows = preg_split('/\|-/', $filmSection);
        foreach ($tableRows as $tr) {
            $cells = preg_split('/\|\|?/', $tr);
            foreach ($cells as $ci => $cell) {
                if ($ci === 0) continue;
                if (preg_match_all('/\'{2}\s*\[\[([^\]|]+?)(?:\|([^\]]+))?\]\]\s*\'{2}/', $cell, $m)) {
                    foreach ($m[2] as $d) {
                        $t = trim($d);
                        if ($t !== '' && mb_strlen($t) >= 2) $titles[] = $t;
                    }
                    foreach ($m[1] as $i => $lt) {
                        if (empty($m[2][$i]) || trim($m[2][$i]) === '') {
                            $t = trim($lt);
                            if ($t !== '' && mb_strlen($t) >= 2) $titles[] = $t;
                        }
                    }
                } elseif (preg_match_all('/\'{2}\s*(.+?)\s*\'{2}/', $cell, $m2)) {
                    foreach ($m2[1] as $plain) {
                        $cleaned = preg_replace('/{{[^}]+}}/u', '', $plain);
                        $cleaned = preg_replace('/<ref[^>]*>.*?<\/ref>/ui', '', $cleaned);
                        $cleaned = trim($cleaned);
                        if ($cleaned !== '' && mb_strlen($cleaned) >= 3 && mb_strlen($cleaned) <= 100 && !preg_match('/^\d+$/', $cleaned)) {
                            $titles[] = $cleaned;
                        }
                    }
                } elseif (preg_match_all('/\[\[([^\]|]+?)(?:\|([^\]]+))?\]\]/', $cell, $m3)) {
                    foreach ($m3[2] as $d) {
                        $t = trim($d);
                        if ($t !== '' && mb_strlen($t) >= 3) $titles[] = $t;
                    }
                    foreach ($m3[1] as $i => $lt) {
                        if (empty($m3[2][$i]) || trim($m3[2][$i]) === '') {
                            $t = trim($lt);
                            if ($t !== '' && mb_strlen($t) >= 3) $titles[] = $t;
                        }
                    }
                }
            }
        }
    }

    $excludePattern = '/^(?:sinh.năm|nơi.sinh|nghề.nghiệp|đạo.diễn|diễn.viên|loạt.phim|phần|season|bài|chương|thể.loại|danh.mục|phim.truyền.hình|thông.tin|chú.thích|tham.khảo|ghi.chú|liên.kết|tài.liệu|nguồn|cameo|vai.khách|vai客串|youku|iqiyi|iqi?yi|bilibili|viki|viu|wetv|mango.tv|mgtv|iq.com|hulu|netflix|amazon.prime|disney\+?|hbomax|hbo.max|apple.tv|paramount|peacock|stan|tvb|cctv|dragon.tv|hunan.tv|zhejiang.tv|jiangsu.tv|beijing.tv|ifeng|tencent|netease|sohu|sina|weibo|xinhua|mtime|东方卫视|浙江卫视|江苏卫视|湖南卫视|北京卫视|安徽卫视|山东卫视|深圳卫视|广东卫视|东方|番茄|优酷|爱奇艺|腾讯|搜狐|芒果|b站|哔哩|beijing.news|china.movie.channel|shanghai.film)/iu';
    $categoryPattern = '/^(?:Category:|Danh.mục:)/iu';

    $seen = [];
    $unique = [];
    foreach ($titles as $t) {
        $t = trim($t);
        $t = preg_replace('/^\'{2,}/', '', $t);
        $t = preg_replace('/\'{2,}$/', '', $t);
        $t = trim($t);
        if ($t === '' || mb_strlen($t) < 2) continue;
        if (preg_match($excludePattern, $t)) continue;
        if (preg_match($categoryPattern, $t)) continue;
        $key = afNormalizeTitle($t);
        if (!isset($seen[$key]) && mb_strlen($t) >= 2) {
            $seen[$key] = true;
            $unique[] = $t;
        }
    }
    return array_values($unique);
}

function afGetWikipediaTitles(string $actorName): array {
    $allTitles = [];

    $langs = [
        ['domain' => 'vi.wikipedia.org'],
        ['domain' => 'en.wikipedia.org'],
    ];

    foreach ($langs as $ld) {
        $pageName = str_replace(' ', '_', $actorName);
        $apiUrl = "https://{$ld['domain']}/w/api.php?action=parse&page=" . rawurlencode($pageName) . "&prop=wikitext&format=json&formatversion=2";

        $json = afFetch($apiUrl);
        if (!$json) continue;
        $data = json_decode($json, true);
        if (!$data || !isset($data['parse']['wikitext'])) continue;

        $wikitext = $data['parse']['wikitext'];
        $found = afParseFilmographyFromWikitext($wikitext);
        $allTitles = array_merge($allTitles, $found);

        if (count($allTitles) >= 5) break;

        $searchUrl = "https://{$ld['domain']}/w/api.php?action=opensearch&search=" . rawurlencode($actorName) . "&limit=3&format=json";
        $searchJson = afFetch($searchUrl);
        if (!$searchJson) continue;
        $searchData = json_decode($searchJson, true);
        if (empty($searchData[1])) continue;

        foreach ($searchData[1] as $suggestedPage) {
            if (mb_strtolower($suggestedPage) === mb_strtolower($pageName)) continue;
            $apiUrl2 = "https://{$ld['domain']}/w/api.php?action=parse&page=" . rawurlencode($suggestedPage) . "&prop=wikitext&format=json&formatversion=2";
            $json2 = afFetch($apiUrl2);
            if (!$json2) continue;
            $data2 = json_decode($json2, true);
            if (!$data2 || !isset($data2['parse']['wikitext'])) continue;
            $found2 = afParseFilmographyFromWikitext($data2['parse']['wikitext']);
            $allTitles = array_merge($allTitles, $found2);
        }

        if (count($allTitles) >= 5) break;
    }

    $seen = [];
    $unique = [];
    foreach ($allTitles as $t) {
        $key = afNormalizeTitle($t);
        if (!isset($seen[$key])) {
            $seen[$key] = true;
            $unique[] = $t;
        }
    }
    return array_values($unique);
}

function afGetTmdbMovieCredits(int $tmdbId): array {
    $resolve = defined('TMDB_RESOLVE') && TMDB_RESOLVE ? ['api.themoviedb.org:443:' . TMDB_RESOLVE] : [];
    $movies = [];

    $url = TMDB_BASE . "/person/{$tmdbId}/movie_credits?api_key=" . TMDB_API_KEY;
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 10, CURLOPT_SSL_VERIFYPEER => false,
        CURLOPT_USERAGENT => 'PhimHay/1.0 (actor-filmography)',
        CURLOPT_RESOLVE => $resolve,
    ]);
    $res = curl_exec($ch); curl_close($ch);
    $data = $res ? json_decode($res, true) : null;
    foreach ($data['cast'] ?? [] as $c) {
        $movies[] = [
            'id'        => $c['id'],
            'title'     => $c['title'] ?? '',
            'original'  => $c['original_title'] ?? '',
            'character' => $c['character'] ?? '',
            'poster'    => !empty($c['poster_path']) ? 'https://image.tmdb.org/t/p/w500' . $c['poster_path'] : null,
            'year'      => !empty($c['release_date']) ? substr($c['release_date'], 0, 4) : null,
            'rating'    => $c['vote_average'] ?? 0,
            'media_type'=> 'movie',
        ];
    }

    $urlTv = TMDB_BASE . "/person/{$tmdbId}/tv_credits?api_key=" . TMDB_API_KEY;
    $ch2 = curl_init($urlTv);
    curl_setopt_array($ch2, [
        CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 10, CURLOPT_SSL_VERIFYPEER => false,
        CURLOPT_USERAGENT => 'PhimHay/1.0 (actor-filmography)',
        CURLOPT_RESOLVE => $resolve,
    ]);
    $res2 = curl_exec($ch2); curl_close($ch2);
    $data2 = $res2 ? json_decode($res2, true) : null;
    foreach ($data2['cast'] ?? [] as $c) {
        $movies[] = [
            'id'        => $c['id'],
            'title'     => $c['name'] ?? '',
            'original'  => $c['original_name'] ?? '',
            'character' => $c['character'] ?? '',
            'poster'    => !empty($c['poster_path']) ? 'https://image.tmdb.org/t/p/w500' . $c['poster_path'] : null,
            'year'      => !empty($c['first_air_date']) ? substr($c['first_air_date'], 0, 4) : null,
            'rating'    => $c['vote_average'] ?? 0,
            'media_type'=> 'tv',
        ];
    }

    usort($movies, fn($a, $b) => ($b['rating'] ?? 0) <=> ($a['rating'] ?? 0));
    return $movies;
}

function afStripYear(string $s): string {
    return trim(preg_replace('/\b\d{4}\b/', '', $s));
}

function afTitlesMatch(string $wikiTitle, string $tmdbTitle, string $tmdbOriginal): bool {
    $wn = afNormalizeTitle($wikiTitle);
    $tn = afNormalizeTitle($tmdbTitle);
    $to = afNormalizeTitle($tmdbOriginal);

    if ($wn === '' && $tn === '' && $to === '') return false;

    if ($wn === $tn || $wn === $to) return true;

    $wnY = afNormalizeTitle(afStripYear($wikiTitle));
    $tnY = afNormalizeTitle(afStripYear($tmdbTitle));
    $toY = afNormalizeTitle(afStripYear($tmdbOriginal));
    if ($wnY !== '' && ($wnY === $tnY || $wnY === $toY)) return true;

    if ($wn !== '' && $tn !== '' && mb_strlen($wn) >= 3 && mb_strlen($tn) >= 3) {
        if (mb_strpos($tn, $wn) !== false && mb_strlen($wn) >= mb_strlen($tn) * 0.5) return true;
        if (mb_strpos($wn, $tn) !== false && mb_strlen($tn) >= mb_strlen($wn) * 0.5) return true;
    }
    if ($wn !== '' && $to !== '' && mb_strlen($wn) >= 3 && mb_strlen($to) >= 3) {
        if (mb_strpos($to, $wn) !== false && mb_strlen($wn) >= mb_strlen($to) * 0.5) return true;
        if (mb_strpos($wn, $to) !== false && mb_strlen($to) >= mb_strlen($wn) * 0.5) return true;
    }

    return false;
}

try {
    $wikiTitles = afGetWikipediaTitles($actorName);

    if (empty($wikiTitles)) {
        echo json_encode(['success' => false, 'error' => 'Không tìm thấy phim nào cho "' . $actorName . '"']);
        exit;
    }

    if (!$syncAll) {
        echo json_encode([
            'success' => true,
            'source'  => 'filmography',
            'titles'  => $wikiTitles,
            'count'   => count($wikiTitles),
        ]);
        exit;
    }

    $filteredTmdb = [];
    $tmdbRemoved = 0;
    $tmdbKept = 0;
    if ($tmdbId) {
        $tmdbMovies = afGetTmdbMovieCredits($tmdbId);
        foreach ($tmdbMovies as $c) {
            $matched = false;
            foreach ($wikiTitles as $wt) {
                if (afTitlesMatch($wt, $c['title'] ?? '', $c['original'] ?? '')) {
                    $matched = true;
                    break;
                }
            }
            if ($matched) {
                $tmdbKept++;
                $filteredTmdb[] = $c;
            } else {
                $tmdbRemoved++;
            }
        }
        usort($filteredTmdb, fn($a, $b) => ($b['rating'] ?? 0) <=> ($a['rating'] ?? 0));

        $db->prepare("UPDATE actors SET movies_json = ?, wiki_movies = ? WHERE tmdb_id = ?")
           ->execute([json_encode($filteredTmdb, JSON_UNESCAPED_UNICODE), json_encode($wikiTitles, JSON_UNESCAPED_UNICODE), $tmdbId]);
    } else {
        $db->prepare("UPDATE actors SET wiki_movies = ? WHERE name = ? OR name_vi = ?")
           ->execute([json_encode($wikiTitles, JSON_UNESCAPED_UNICODE), $actorName, $actorName]);
    }

    if (!$tmdbId) {
        $sFindTmdb = $db->prepare("SELECT tmdb_id FROM actors WHERE name = ? OR name_vi = ? LIMIT 1");
        $sFindTmdb->execute([$actorName, $actorName]);
        $rFindTmdb = $sFindTmdb->fetch();
        if ($rFindTmdb) $tmdbId = (int)$rFindTmdb['tmdb_id'];
    }
    if ($tmdbId) {
        $sOld = $db->prepare("SELECT movies_json FROM actors WHERE tmdb_id = ? LIMIT 1");
        $sOld->execute([$tmdbId]);
        $rOld = $sOld->fetch();
        if ($rOld) {
            $oldMovies = json_decode($rOld['movies_json'] ?? '[]', true);
            $wikiNorm = [];
            foreach ($wikiTitles as $wt) {
                $wn = afNormalizeTitle($wt);
                if ($wn !== '') $wikiNorm[$wn] = true;
            }
            $cleaned = [];
            foreach ($oldMovies as $om) {
                $orig = afNormalizeTitle($om['original'] ?? $om['title'] ?? '');
                $tit = afNormalizeTitle($om['title'] ?? '');
                $keep = false;
                if ($orig !== '' && isset($wikiNorm[$orig])) $keep = true;
                if ($tit !== '' && isset($wikiNorm[$tit])) $keep = true;
                if (!$keep) {
                    foreach ($wikiNorm as $wn => $_) {
                        if ($wn !== '' && mb_strlen($wn) >= 3 && ($orig === $wn || $tit === $wn)) { $keep = true; break; }
                    }
                }
                if ($keep) $cleaned[] = $om;
            }
            if (count($cleaned) !== count($oldMovies)) {
                $db->prepare("UPDATE actors SET movies_json = ? WHERE tmdb_id = ?")
                   ->execute([json_encode($cleaned, JSON_UNESCAPED_UNICODE), $tmdbId]);
            }
        }
    }

    $existingSlugs = [];
    $stmtE = $db->prepare("SELECT slug, origin_name, name FROM movies ORDER BY view_count DESC LIMIT 5000");
    $stmtE->execute();
    while ($er = $stmtE->fetch()) {
        $existingSlugs[strtolower($er['slug'])] = true;
        $existingSlugs[afNormalizeTitle($er['origin_name'] ?? '')] = true;
        $existingSlugs[afNormalizeTitle($er['name'] ?? '')] = true;
    }

    $results = [];
    $synced = 0;
    $skipped = 0;
    $failed = 0;

    foreach ($wikiTitles as $title) {
        $normTitle = afNormalizeTitle($title);
        $alreadyInDb = isset($existingSlugs[$normTitle]);

        if (!$alreadyInDb) {
            $stmtCheck = $db->prepare("SELECT id FROM movies WHERE LOWER(origin_name) = ? OR LOWER(name) = ? LIMIT 1");
            $stmtCheck->execute([$normTitle, $normTitle]);
            if ($stmtCheck->fetch()) {
                $alreadyInDb = true;
                $existingSlugs[$normTitle] = true;
            }
        }

        if ($alreadyInDb) {
            $skipped++;
            $results[] = ['title' => $title, 'status' => 'exists'];
            continue;
        }

        usleep(300000);
        $syncResult = afSyncSingleMovie($db, $title);

        if ($syncResult['success']) {
            $synced++;
            $slug = $syncResult['slug'] ?? '';
            $existingSlugs[strtolower($slug)] = true;
            $existingSlugs[afNormalizeTitle($title)] = true;
            $results[] = [
                'title'  => $title,
                'status' => $syncResult['action'] ?? 'synced',
                'slug'   => $slug,
            ];
        } else {
            $failed++;
            $results[] = ['title' => $title, 'status' => 'not_found'];
        }
    }

    echo json_encode([
        'success'      => true,
        'source'       => 'wikipedia',
        'total'        => count($wikiTitles),
        'synced'       => $synced,
        'skipped'      => $skipped,
        'failed'       => $failed,
        'tmdb_kept'    => $tmdbKept,
        'tmdb_removed' => $tmdbRemoved,
        'results'      => $results,
    ]);

} catch (Exception $e) {
    echo json_encode(['success' => false, 'error' => $e->getMessage()]);
}
