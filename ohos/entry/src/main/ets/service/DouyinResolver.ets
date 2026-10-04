/**
 * 抖音 WebView 解析器（v1.28.0，videdown puppeteer 方案同构）
 *
 * v1.28.0 重构（多轮"解析失败"的最终修复）：
 * 此前加载的是 iesdouyin 分享页 + iOS UA——分享页是风控最重的入口，
 * 挑战壳之后数据也不保证回归。videdown 在桌面端能稳定工作的核心是：
 * 加载 www.douyin.com 桌面页（Chrome UA），页面自身 JS 会调
 * /aweme/v1/web/aweme/detail/ 拉数据，无头浏览器只需"监听"该 API 响应。
 * ArkWeb 等价实现：
 * 1. javaScriptOnDocumentStart 注入 fetch/XHR 钩子——页面自己发的
 *    detail API 响应被捕获进 window.__DY_API__（等价 puppeteer 的
 *    page.on('response') 网络拦截，最难被封的取数方式）。
 * 2. 加载 https://www.douyin.com/{video|note|slides}/{id} 桌面页 + 桌面
 *    Chrome UA；轮询读 __DY_API__ → _SSR_HYDRATED_DATA/__INITIAL_STATE__
 *    （videdown 同款 SSR 水合探查）→ _ROUTER_DATA → DOM video src。
 * 3. 注入时若数据未就绪，顺手点一下播放按钮触发视频加载（videdown 同款）。
 */
import { webview } from '@kit.ArkWeb';

/** 桌面 Chrome UA（www.douyin.com 桌面页用，videdown 同款）。 */
const RESOLVER_UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/**
 * document-start 注入：hook fetch/XHR，捕获页面自身发出的 detail API 响应
 * 存入 window.__DY_API__（幂等，挑战跳转后的每个文档重新安装）。
 */
const HOOK_JS: string = `(function () {
  if (window.__DY_HOOK__) { return; }
  window.__DY_HOOK__ = true;
  window.__DY_API__ = '';
  function dyCapture(u, body) {
    try {
      if (!u || !body) { return; }
      var s = String(u);
      if (s.indexOf('/aweme/v1/web/aweme/detail/') < 0 &&
        s.indexOf('/aweme/v1/multi/aweme/detail/') < 0 &&
        s.indexOf('/aweme/v1/aweme/detail/') < 0 &&
        s.indexOf('iteminfo') < 0 && s.indexOf('/aweme/v1/feed/') < 0) { return; }
      var b = String(body);
      if (b.length > 100 && (b.indexOf('aweme_detail') >= 0 || b.indexOf('item_list') >= 0)) {
        window.__DY_API__ = b;
      }
    } catch (e) {}
  }
  try {
    var of = window.fetch;
    if (of) {
      window.fetch = function () {
        var args = arguments;
        var u = '';
        try { u = (args[0] && args[0].url) ? String(args[0].url) : String(args[0]); } catch (e) {}
        return of.apply(this, args).then(function (resp) {
          try {
            var c = resp.clone();
            if (c && c.text) { c.text().then(function (t) { dyCapture(u, t); }).catch(function () {}); }
          } catch (e) {}
          return resp;
        });
      };
    }
  } catch (fe) {}
  try {
    var oOpen = XMLHttpRequest.prototype.open;
    var oSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (m, u) {
      try { this.__dyu = String(u); } catch (e) {}
      return oOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var self = this;
      try {
        this.addEventListener('readystatechange', function () {
          if (self.readyState === 4) { try { dyCapture(self.__dyu, self.responseText); } catch (e) {} }
        });
      } catch (e) {}
      return oSend.apply(this, arguments);
    };
  } catch (xe) {}
})();`;

/** document-start 脚本项（SDK 11+ 要求 ScriptItem[] + 作用域规则）。 */
const HOOK_ITEMS: ScriptItem[] = [
  { script: HOOK_JS, scriptRules: ['*://*.douyin.com/*', '*://*.iesdouyin.com/*'] }
];

/** 注入脚本：① document-start 钩子捕获的 detail API 原始 JSON →
 *  ② SSR 水合数据（videdown 同款探查）→ ③ _ROUTER_DATA → ④ DOM/ld+json。 */
const RESOLVER_JS: string = `(function () {
  try {
    var cap = window.__DY_API__;
    if (cap && cap.length > 100 && (cap.indexOf('aweme_detail') >= 0 || cap.indexOf('item_list') >= 0)) {
      return cap;
    }
  } catch (capError) {}
  try {
    var ssr = window._SSR_HYDRATED_DATA;
    var sDetail = null;
    if (ssr) {
      sDetail = ssr.aweme_detail || (ssr.aweme && ssr.aweme.aweme_detail) ||
        (ssr.app && ssr.app.aweme_detail) || (ssr.aweme && ssr.aweme.detail);
    }
    if (!sDetail) {
      var st = window.__INITIAL_STATE__;
      if (st) {
        sDetail = st.aweme_detail || (st.aweme && st.aweme.aweme_detail) ||
          (st.app && st.app.aweme_detail);
      }
    }
    if (sDetail && (sDetail.video || sDetail.images || sDetail.desc)) {
      return JSON.stringify({ aweme_detail: sDetail });
    }
  } catch (ssrError) {}
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
  if (title.length === 0 || (isImagePost && images.length === 0) ||
    (!isImagePost && videoUrl.length === 0)) {
    try {
      var playBtn = document.querySelector('.play-button, [data-e2e="play-button"], .player-play, .video-play');
      if (playBtn && playBtn.click) { playBtn.click(); }
    } catch (clickError) {}
    return '{}';
  }
  if (author.length === 0) {
    author = '抖音创作者';
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
const MAX_ATTEMPTS: number = 14;
const RETRY_DELAY_MS: number = 1400;
/** 解析总超时：挑战跳转 + 异步数据可能超过 30s。 */
const RESOLVE_TIMEOUT_MS: number = 45000;
/** loadUrl 失败重试上限（控制器未就绪等瞬时错误）。 */
const MAX_LOAD_RETRIES: number = 6;

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
      }, RESOLVE_TIMEOUT_MS);
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
 *  v1.26.7 重构修复（真机上 WebView 通道从未生效的根因）：
 *  ArkWeb 的 loadUrl 必须在控制器 attach 之后调用——此前 aboutToAppear 注册
 *  loader 时控制器尚未 attach，应用启动后立刻解析会触发 "controller not
 *  attached" 异常，catch 后 finish('') 静默失败，WebView 通道形同虚设。
 *  现在 loader 在未 ready 时缓存 URL，onControllerAttached 后立即加载；
 *  loadUrl 瞬时失败也按计数重试而非直接放弃。 */
@Component
export struct DouyinWebResolver {
  @State currentUrl: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  /** 当前页面的注入尝试计数（页面跳转重置）。 */
  private attempts: number = 0;
  /** 控制器是否已 attach（attach 后 loadUrl 才可用）。 */
  private ready: boolean = false;
  /** 未 ready 期间到达的加载请求。 */
  private pendingUrl: string = '';
  /** loadUrl 瞬时失败计数。 */
  private loadRetries: number = 0;

  aboutToAppear(): void {
    DouyinResolverBridge.loader = (url: string): void => {
      this.currentUrl = url;
      this.attempts = 0;
      this.loadRetries = 0;
      if (!this.ready) {
        // 控制器尚未 attach：缓存 URL，onControllerAttached 后加载
        this.pendingUrl = url;
        return;
      }
      this.loadWithRetry(url);
    };
  }

  aboutToDisappear(): void {
    DouyinResolverBridge.loader = null;
  }

  private loadWithRetry(url: string): void {
    try {
      this.controller.loadUrl(url);
    } catch (e) {
      // 控制器瞬时不可用：重试而不是放弃（放弃=整个解析静默失败）
      this.loadRetries++;
      if (this.loadRetries > MAX_LOAD_RETRIES) {
        DouyinResolverBridge.finish('');
        return;
      }
      const next = url;
      setTimeout((): void => {
        if (DouyinResolverBridge.hasPending()) {
          this.loadWithRetry(next);
        }
      }, 1000);
    }
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
      .javaScriptOnDocumentStart(HOOK_ITEMS)
      .onControllerAttached(() => {
        this.ready = true;
        if (this.pendingUrl.length > 0) {
          const url = this.pendingUrl;
          this.pendingUrl = '';
          this.loadWithRetry(url);
        }
      })
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
