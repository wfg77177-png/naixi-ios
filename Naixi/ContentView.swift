import SwiftUI
import WebKit

// MARK: - JS injected into every Naixi page
// Minimal only: sign-in (button click, once/day), section navigation,
// back to top, toast. No dark mode, no ad hiding, no keyword filter,
// no fullscreen image viewer, no scroll restore, no read markers,
// no infinite scroll, no folding, no only-OP, no export, no image
// save, no notes/blacklist, no highlight, no templates, no code
// copy, no translation, no long-press preview.
// localStorage holds ONLY the sign-in date guard ('nx_signDate').
// Login state lives in the WKWebView system cookie jar.
private let nxJS = """
(function(){
function store(k,v){ try{ localStorage.setItem('nx_'+k, v);}catch(e){}}
function read(k,d){ try{ var v=localStorage.getItem('nx_'+k); return v===null?d:v;}catch(e){ return d;}}

function showToast(msg){
var t=document.createElement('div');
t.textContent=msg;
t.style.cssText='position:fixed;left:50%;bottom:90px;transform:translateX(-50%);background:rgba(0,0,0,0.82);color:#fff;padding:10px 16px;border-radius:20px;font-size:14px;z-index:999999;pointer-events:none;';
document.body.appendChild(t);
setTimeout(function(){ t.remove();}, 2600);
}
window.__nxToast = showToast;

// Sign-in: click the forum's own sign-in button.
// The forum sign-in endpoint is unverified, so no API call is made.
// This only clicks the button the site itself renders, using the
// webview's own session cookie. At most once per day (date guard).
// Auto sign-in runs ONLY from webView didFinish; the manual toolbar
// button works any time the user taps it.
function findSignInEl(){
var els = document.querySelectorAll('a, button');
for (var i=0;i<els.length;i++){
var t=(els[i].textContent||'').trim();
if(t==='签到' || t==='每日签到' || t.indexOf('签到')===0){ return els[i];}
}
var imgs = document.querySelectorAll('img[alt*="签到"], img[title*="签到"]');
for (var j=0;j<imgs.length;j++){
var a=imgs[j].closest('a'); if(a) return a;
}
return null;
}
window.__nxClickSignIn = function(manual){
var el = findSignInEl();
if(!el){
if(manual) showToast('未找到签到按钮，请在页面里点签到');
return false;
}
el.click();
store('signDate', new Date().toISOString().slice(0,10));
if(manual) showToast('已点签到');
return true;
};
window.__nxAutoSignIn = function(){
var p = location.pathname;
var isIndex = (p==='/' || p==='/forum.php' || p.indexOf('forum.php')!==-1);
if(!isIndex) return;
var today = new Date().toISOString().slice(0,10);
if (read('signDate','') === today) return;
setTimeout(function(){
var el = findSignInEl();
if(el){ el.click(); store('signDate', today);}
}, 1200);
};

// Section navigation (tap a board name in the native picker).
// Board names are verified from the live homepage; links are found by
// name (brackets stripped), never by hardcoded board URLs.
window.__nxGoSection = function(name){
var links = Array.prototype.slice.call(document.querySelectorAll('a'));
function clean(t){ return (t||'').replace(/[\\[\\]\\s]/g,'');}
var cands = links.filter(function(a){
var href = a.getAttribute('href')||'';
return clean(a.textContent)===name && href && href.indexOf('/')===0;
});
if(!cands.length) return false;
var hit = cands.find(function(a){
var h=a.getAttribute('href')||'';
return h.indexOf('forum')!==-1 || h.indexOf('fid=')!==-1;
}) || cands[0];
hit.click(); return true;
};

// Back to top.
window.__nxTop = function(){ window.scrollTo({top:0, behavior:'smooth'});};
})();
"""

// MARK: - Model
final class BrowserModel: ObservableObject {
    weak var webView: WKWebView?
    @Published var searchHistory: [String] = []

    let homeURL = URL(string: "https://forum.naixi.net/")!
    let newAPIURL = URL(string: "https://newapi.naixi.net/")!
    // Board names verified from the live homepage (2026-11-17).
    let sections = ["eSIM", "日常", "技术", "推广", "运营商", "人工智能", "问答", "交易", "果粉", "开户", "宽带症候群", "市场"]

    func load(_ url: URL) {
        webView?.load(URLRequest(url: url))
    }
    func goHome() { load(homeURL) }
    func goNewAPI() { load(newAPIURL) }
    func goLogin() { load(URL(string: "https://forum.naixi.net/member.php?mod=logging&action=login")!) }
    func reload() { webView?.reload() }
    func backToTop() {
        webView?.evaluateJavaScript("window.__nxTop && window.__nxTop();", completionHandler: nil)
    }
    func goSection(_ name: String) {
        webView?.evaluateJavaScript("window.__nxGoSection && window.__nxGoSection('\(name)');") { _, _ in }
    }
    func manualSignIn() {
        webView?.evaluateJavaScript("window.__nxClickSignIn && window.__nxClickSignIn(true);", completionHandler: nil)
    }
    func search(_ q: String) {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        var hist = searchHistory
        hist.removeAll { $0 == query }
        hist.insert(query, at: 0)
        if hist.count > 10 { hist = Array(hist.prefix(10)) }
        searchHistory = hist
        UserDefaults.standard.set(hist, forKey: "nx_searchHist")
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        if let url = URL(string: "https://forum.naixi.net/search.php?mod=forum&srchtxt=\(enc)&searchsubmit=yes") {
            load(url)
        }
    }
    func goSearchPage() {
        if let url = URL(string: "https://forum.naixi.net/search.php?mod=forum") { load(url) }
    }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var model = BrowserModel()
    @State private var showSections = false

    var body: some View {
        ZStack(alignment: .bottom) {
            WebView(model: model)
            BottomBar(model: model, showSections: $showSections)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSections) { SectionSheet(model: model) }
        .onAppear {
            model.searchHistory = UserDefaults.standard.stringArray(forKey: "nx_searchHist") ?? []
        }
    }
}

// MARK: - WebView
// Speed: the WKWebView is the eager root view — created as soon as the
// app opens and loading the forum homepage immediately. The data store
// is explicitly the default persistent one (cache + cookies persist
// across launches; repeat opens reuse the cache). Cache/cookies are
// never cleared, the store is never .nonPersistent(), and reloads never
// ignore the local cache.
struct WebView: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let endScript = WKUserScript(source: nxJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(endScript)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.bounces = true
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        // leave room so the last line is never hidden behind the bottom bar
        webView.scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        webView.scrollView.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 76, right: 0)
        webView.load(URLRequest(url: model.homeURL))
        model.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }
        // Links that open in a new window (target="_blank", e.g. search results
        // and second-level pages) would otherwise do nothing: WKWebView has no
        // second web view to hand them to. Load them in this same web view.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Once-per-day auto sign-in, now the page is truly loaded
            // (not on a half-loaded or challenge page).
            webView.evaluateJavaScript(
                "window.__nxAutoSignIn && window.__nxAutoSignIn();",
                completionHandler: nil)
        }
    }
}

// MARK: - Bottom bar (6 buttons only)
struct BottomBar: View {
    @ObservedObject var model: BrowserModel
    @Binding var showSections: Bool

    var body: some View {
        HStack(spacing: 2) {
            BarButton(icon: "house", label: "首页") { model.goHome() }
            BarButton(icon: "square.grid.2x2", label: "分区") { showSections = true }
            BarButton(icon: "checkmark.seal", label: "签到") { model.manualSignIn() }
            BarButton(icon: "bolt", label: "API") { model.goNewAPI() }
            BarButton(icon: "arrow.up", label: "顶部") { model.backToTop() }
            BarButton(icon: "person.crop.circle", label: "登录") { model.goLogin() }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }
}

struct BarButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

// MARK: - Section picker sheet
struct SectionSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("搜索帖子…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit {
                            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                model.search(searchText)
                                dismiss()
                            }
                        }
                    if !model.searchHistory.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.searchHistory, id: \.self) { h in
                                    Button(h) {
                                        model.search(h)
                                        dismiss()
                                    }
                                    .font(.system(size: 13))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(.secondarySystemBackground), in: Capsule())
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    Button("站内搜索页") { model.goSearchPage(); dismiss() }
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.sections, id: \.self) { name in
                        Button {
                            model.goSection(name)
                            dismiss()
                        } label: {
                            Text(name)
                                .font(.system(size: 16, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("分区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
