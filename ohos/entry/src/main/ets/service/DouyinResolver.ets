/**
 * 抖音 WebView 解析器（v1.26.6，SaveAny DouyinWebResolver 同构）
 *
 * 直连通道已被抖音 JS 挑战壳拦截（分享页返回空 body + jsvmp 混淆脚本，
 * _ROUTER_DATA 不再出现在首屏 HTML），WebView 内核执行挑战脚本跳到真实
 * 页面后仍能拿到完整作品数据——这是直连失败后的唯一兜底通道。
 *
 * v1.26.6 修复（解析仍全败的根因）：
 * 1. Web 组件此前 .visibility(Hidden) 不参与渲染，WebView 可能不加载页面
 *    /不执行挑战 JS——改为渲染在屏外（position 屏外 + opacity 0.01）。
 * 2. 注入此前只在 onPageEnd 后执行一次，挑战跳转/异步数据未就绪时取空——
 *    改为多轮重试注入（每轮失败后 1.4s 再试，页面每次跳转重置计数，
 *    最多 8 次或拿到有效数据为止），由桥统一幂等交付。
 * 3. 服务层 resolve reject（busy/未挂载）此前未捕获会中断整个解析——
 *    调用侧已改为 try-catch。
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

/** 单次解析的注入尝试上限与间隔（挑战跳转后每次 onPageEnd 重置）。 */
const MAX_ATTEMPTS: number = 8;
const RETRY_DELAY_MS: number = 1400;

/**
 * 服务层调用的桥（单例）：resolve(pageUrl) → Promise<json 字符串>。
 * 超时 30s 兜底；同一时刻只允许一个解析；finish 幂等。
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

  /** 组件回调完成：清理并交付结果（幂等，重复调用忽略）。 */
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

  /** 当前是否有等待中的解析请求（组件侧注入循环的停止条件）。 */
  static hasPending(): boolean {
    return DouyinResolverBridge.pending !== null;
  }
}

/** 隐藏 Web 解析组件：Index 根 Stack 常驻挂载。
 *  v1.26.6：屏外渲染（position 移出视口 + opacity 0.01），保证 WebView
 *  正常加载页面并执行 JS 挑战脚本——此前 Hidden 不渲染导致加载不启动。 */
@Component
export struct DouyinWebResolver {
  @State currentUrl: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  /** 当前页面的注入尝试计数（页面跳转重置）。 */
  private attempts: number = 0;

  aboutToAppear(): void {
    DouyinResolverBridge.loader = (url: string): void => {
      try {
        this.currentUrl = url;
        this.attempts = 0;
        this.controller.loadUrl(url);
      } catch (e) {
        DouyinResolverBridge.finish('');
      }
    };
  }

  aboutToDisappear(): void {
    DouyinResolverBridge.loader = null;
  }

  /** 单轮注入：有效 JSON 立即交付；无效则按重试间隔再试，至上限。 */
  private injectOnce(): void {
    if (!DouyinResolverBridge.hasPending()) {
      // 上游已超时/取消，停止
      return;
    }
    try {
      this.controller.runJavaScript(RESOLVER_JS)
        .then((value: string): void => {
          const text: string = (value !== undefined && value !== null) ? value : '';
          if (text.length > 2) {
            DouyinResolverBridge.finish(text);
            return;
          }
          this.scheduleRetry();
        })
        .catch((): void => {
          this.scheduleRetry();
        });
    } catch (e) {
      this.scheduleRetry();
    }
  }

  private scheduleRetry(): void {
    this.attempts++;
    if (this.attempts >= MAX_ATTEMPTS) {
      DouyinResolverBridge.finish('');
      return;
    }
    setTimeout((): void => {
      this.injectOnce();
    }, RETRY_DELAY_MS);
  }

  build() {
    Web({ src: 'about:blank', controller: this.controller, renderMode: RenderMode.SYNC_RENDER })
      .width(320)
      .height(240)
      .opacity(0.01)
      .position({ x: -4000, y: -4000 })
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .multiWindowAccess(false)
      .zoomAccess(false)
      .userAgent(RESOLVER_UA)
      .onPageEnd(() => {
        // 挑战脚本跳转会再次触发 onPageEnd：重置计数重新注入
        this.attempts = 0;
        setTimeout((): void => {
          this.injectOnce();
        }, 800);
      })
      .onErrorReceive(() => {
        // 静默：由重试/超时兜底
      })
  }
}
