/**
 * 抖音 WebView 解析器（v1.26.5，SaveAny DouyinWebResolver 同构）
 *
 * 直连通道被抖音风控/异步加载拦住时兜底：隐藏 Web 组件加载分享页，
 * onPageEnd 后注入 JS 抓 _ROUTER_DATA + DOM（视频/图集直链、标题、作者），
 * 返回 JSON 字符串交由 DouyinService.fromResolverJson 映射。
 * 服务层通过 DouyinResolverBridge 调用；Web 组件由 Index 根 Stack 常驻挂载。
 */
import { webview } from '@kit.ArkWeb';

/** 通用移动端 UA（iOS Safari，与直连通道一致）。 */
const RESOLVER_UA: string = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 ' +
  '(KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1';

/** 注入脚本：优先读运行时 _ROUTER_DATA，备用 DOM/ld+json 兜底。 */
const RESOLVER_JS: string = `(function () {
  var mediaElements = document.querySelectorAll('video, audio');
  for (var mediaIndex = 0; mediaIndex < mediaElements.length; mediaIndex++) {
    try {
      mediaElements[mediaIndex].muted = true;
    } catch (mediaError) {}
  }
  var pathMatch = location.pathname.match(/\\/(video|note|slides)\\/(\\d+)/);
  var postType = pathMatch ? pathMatch[1] : '';
  var postId = pathMatch ? pathMatch[2] : '';
  var isImagePost = postType === 'note' || postType === 'slides';
  var title = '';
  var author = '';
  var images = [];
  var musicUrl = '';
  var videoUrl = '';
  var coverUrl = '';
  var width = 0;
  var height = 0;
  try {
    var routerData = window._ROUTER_DATA;
    if (routerData && routerData.loaderData) {
      var pageData = routerData.loaderData['video_(id)/page'] || routerData.loaderData['note_(id)/page'] ||
        routerData.loaderData['slides_(id)/page'];
      var itemList = [];
      if (pageData && pageData.videoInfoRes && pageData.videoInfoRes.item_list) {
        itemList = pageData.videoInfoRes.item_list;
      } else if (pageData && pageData.slidesInfoRes && pageData.slidesInfoRes.aweme_details) {
        itemList = pageData.slidesInfoRes.aweme_details;
      }
      if (itemList.length > 0) {
        var item = itemList[0];
        if (item.desc) {
          title = String(item.desc).trim();
        }
        if (item.author && item.author.nickname) {
          author = String(item.author.nickname).trim();
        }
        if (item.video) {
          width = Number(item.video.width) || 0;
          height = Number(item.video.height) || 0;
          if (item.video.cover && item.video.cover.url_list && item.video.cover.url_list.length > 0) {
            coverUrl = String(item.video.cover.url_list[0]);
          }
          var playAddr = item.video.play_addr;
          if (playAddr) {
            var uri = playAddr.uri ? String(playAddr.uri) : '';
            var candidates = [];
            if (uri.length > 0) {
              candidates.push('https://www.iesdouyin.com/aweme/v1/play/?line=0&video_id=' +
                encodeURIComponent(uri) + '&downgrade_264=1');
            }
            if (playAddr.url_list) {
              for (var candidateIndex = 0; candidateIndex < playAddr.url_list.length; candidateIndex++) {
                candidates.push(String(playAddr.url_list[candidateIndex]));
              }
            }
            var bestScore = -1000;
            for (var candidateIndex2 = 0; candidateIndex2 < candidates.length; candidateIndex2++) {
              var candidateUrl = candidates[candidateIndex2];
              var score = 0;
              if (candidateUrl.indexOf('downgrade_264=1') >= 0) score += 100;
              if (candidateUrl.indexOf('codec_type=0') >= 0 || /[?&]cs=0(?:&|$)/.test(candidateUrl)) score += 60;
              if (candidateUrl.indexOf('h264') >= 0) score += 40;
              if (candidateUrl.indexOf('/aweme/v1/play') >= 0) score += 10;
              if (candidateUrl.indexOf('playwm') >= 0) score -= 20;
              if (candidateUrl.indexOf('h265') >= 0 || candidateUrl.indexOf('hevc') >= 0 ||
                /[?&]cs=2(?:&|$)/.test(candidateUrl)) score -= 40;
              if (score > bestScore) {
                bestScore = score;
                videoUrl = candidateUrl;
              }
            }
          }
        }
        if (item.images && item.images.length > 0) {
          for (var imageIndex = 0; imageIndex < item.images.length; imageIndex++) {
            var imageItem = item.images[imageIndex];
            var imageUrls = imageItem.url_list || imageItem.download_url_list || [];
            if (imageUrls.length > 0) {
              images.push({
                url_list: imageUrls.map(function (value) { return String(value); }),
                width: Number(imageItem.width) || 0,
                height: Number(imageItem.height) || 0
              });
            }
          }
        }
        if (item.music && item.music.play_url && item.music.play_url.url_list &&
          item.music.play_url.url_list.length > 0) {
          musicUrl = String(item.music.play_url.url_list[0]);
        }
      }
    }
  } catch (routerError) {}
  if (!title || !author || (!isImagePost && videoUrl.length === 0)) {
    var authorFallback = '';
    var jsonLdElements = document.querySelectorAll('script[type="application/ld+json"]');
    for (var jsonIndex = 0; jsonIndex < jsonLdElements.length && !authorFallback; jsonIndex++) {
      try {
        var jsonLd = JSON.parse(jsonLdElements[jsonIndex].textContent || '{}');
        var breadcrumbItems = jsonLd.itemListElement || [];
        if (breadcrumbItems.length > 1 && breadcrumbItems[1].name) {
          authorFallback = String(breadcrumbItems[1].name).trim();
        }
      } catch (jsonError) {}
    }
    if (!authorFallback) {
      var authorElements = document.querySelectorAll('main a[href*="/user/"], a[href*="/user/"]');
      for (var authorIndex = 0; authorIndex < authorElements.length && !authorFallback; authorIndex++) {
        var authorHref = String(authorElements[authorIndex].getAttribute('href') || '');
        var authorText = String(authorElements[authorIndex].textContent || '').trim();
        if (authorHref.indexOf('/user/self') < 0 && authorText && authorText !== '我的') {
          authorFallback = authorText;
        }
      }
    }
    if (!authorFallback) {
      var nicknameElement = document.querySelector('.video-card__author__nickname, .author-name');
      if (nicknameElement) {
        authorFallback = String(nicknameElement.textContent || '').trim().replace(/^@/, '');
      }
    }
    if (authorFallback.length > 0) {
      author = authorFallback;
    }
    var titleElement = document.querySelector('h1');
    var titleFallback = titleElement ? String(titleElement.textContent || '').trim() : '';
    if (titleFallback.length === 0) {
      var descElement = document.querySelector('.desc');
      titleFallback = descElement ? String(descElement.textContent || '').trim() : '';
    }
    if (titleFallback.length === 0) {
      var descriptionElement = document.querySelector('meta[name="description"]');
      var metaDescription = descriptionElement ? String(descriptionElement.content || '').trim() : '';
      var metaMatch = metaDescription.match(/^(.*?)\\s*-\\s*(.+?)于\\d{8}发布在抖音/);
      if (metaMatch && metaMatch.length > 2) {
        titleFallback = String(metaMatch[1] || '').trim();
        if (!author) {
          author = String(metaMatch[2] || '').trim();
        }
      } else {
        titleFallback = String(document.title || '').replace(/\\s*-\\s*抖音\\s*$/, '').trim();
      }
    }
    if (titleFallback.length > 0 && titleFallback !== '抖音' && titleFallback.indexOf('记录美好生活') < 0) {
      title = titleFallback;
    }
    if (videoUrl.length === 0) {
      var sourceUrls = [];
      var sourceUrlMap = {};
      for (var mediaIndex2 = 0; mediaIndex2 < mediaElements.length; mediaIndex2++) {
        var mediaUrl = String(mediaElements[mediaIndex2].currentSrc || mediaElements[mediaIndex2].src || '');
        if (mediaUrl.indexOf('http') === 0 && !sourceUrlMap[mediaUrl]) {
          sourceUrlMap[mediaUrl] = true;
          sourceUrls.push(mediaUrl);
        }
      }
      var sourceElements = document.querySelectorAll('video source[src], audio source[src]');
      for (var sourceIndex = 0; sourceIndex < sourceElements.length; sourceIndex++) {
        var sourceUrl = String(sourceElements[sourceIndex].src || '');
        if (sourceUrl.indexOf('http') === 0 && !sourceUrlMap[sourceUrl]) {
          sourceUrlMap[sourceUrl] = true;
          sourceUrls.push(sourceUrl);
        }
      }
      var bestScore2 = -1;
      for (var videoIndex = 0; videoIndex < sourceUrls.length; videoIndex++) {
        var candidate = sourceUrls[videoIndex];
        var score2 = 0;
        if (postId && candidate.indexOf(postId) >= 0) score2 += 10;
        if (candidate.indexOf('douyinvod.com') >= 0) score2 += 40;
        if (candidate.indexOf('/video/tos/') >= 0) score2 += 30;
        if (candidate.indexOf('/aweme/v1/play') >= 0) score2 += 3;
        if (candidate.indexOf('mime_type=video') >= 0) score2 += 5;
        if (candidate.indexOf('h265') >= 0 || candidate.indexOf('hevc') >= 0 ||
          /[?&]cs=2(?:&|$)/.test(candidate)) score2 -= 40;
        if (score2 > bestScore2) {
          bestScore2 = score2;
          videoUrl = candidate;
        }
      }
    }
  }
  if (title.length === 0 || author.length === 0 ||
    (isImagePost && images.length === 0) || (!isImagePost && videoUrl.length === 0)) {
    return '{}';
  }
  return JSON.stringify({
    desc: title,
    author: { nickname: author },
    images: images,
    music: { play_url: { url_list: musicUrl ? [musicUrl] : [] } },
    video: {
      play_addr: { url_list: videoUrl ? [videoUrl] : [] },
      cover: { url_list: coverUrl ? [coverUrl] : [] },
      width: width,
      height: height
    }
  });
})();`;

/**
 * 服务层调用的桥（单例）：resolve(pageUrl) → Promise<json 字符串>。
 * 超时 30s 兜底；同一时刻只允许一个解析。
 */
export class DouyinResolverBridge {
  private static pending: ((jsonText: string) => void) | null = null;
  private static timeoutId: number = -1;
  /** 由 DouyinWebResolver 组件注册的实际加载器。 */
  static loader: ((url: string) => void) | null = null;

  static resolve(pageUrl: string): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void,
      reject: (e: Object) => void) => {
      if (DouyinResolverBridge.pending !== null || DouyinResolverBridge.loader === null) {
        reject(new Error('busy'));
        return;
      }
      DouyinResolverBridge.pending = resolve;
      DouyinResolverBridge.timeoutId = setTimeout((): void => {
        DouyinResolverBridge.finish('');
      }, 30000);
      DouyinResolverBridge.loader(pageUrl);
    });
  }

  /** 组件回调完成：清理并交付结果。 */
  static finish(jsonText: string): void {
    if (DouyinResolverBridge.timeoutId >= 0) {
      clearTimeout(DouyinResolverBridge.timeoutId);
      DouyinResolverBridge.timeoutId = -1;
    }
    const cb = DouyinResolverBridge.pending;
    DouyinResolverBridge.pending = null;
    if (cb !== null) {
      cb(jsonText);
    }
  }
}

/** 隐藏 Web 解析组件：Index 根 Stack 常驻挂载（1px、不可见）。 */
@Component
export struct DouyinWebResolver {
  @State currentUrl: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    DouyinResolverBridge.loader = (url: string): void => {
      try {
        this.currentUrl = url;
        this.controller.loadUrl(url);
      } catch (e) {
        DouyinResolverBridge.finish('');
      }
    };
  }

  aboutToDisappear(): void {
    DouyinResolverBridge.loader = null;
  }

  build() {
    Web({ src: 'about:blank', controller: this.controller, renderMode: RenderMode.SYNC_RENDER })
      .width(1)
      .height(1)
      .opacity(0.01)
      .visibility(Visibility.Hidden)
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .multiWindowAccess(false)
      .zoomAccess(false)
      .userAgent(RESOLVER_UA)
      .onPageEnd(() => {
        setTimeout((): void => {
          try {
            this.controller.runJavaScript(RESOLVER_JS)
              .then((value: string): void => {
                DouyinResolverBridge.finish(value !== undefined && value !== null ? value : '');
              })
              .catch((): void => {
                DouyinResolverBridge.finish('');
              });
          } catch (e) {
            DouyinResolverBridge.finish('');
          }
        }, 800);
      })
      .onErrorReceive(() => {
        // 静默：由超时兜底
      })
  }
}
