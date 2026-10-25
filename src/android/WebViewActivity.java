// zimr's Android shell: one full-screen WebView showing the page packed into the app as assets/index.html.
//
// Every zimr app's APK carries this same compiled class; only its manifest (app ID, name) and its assets differ
// (tools/android_apk.zig, `zig build <app> -Dplatform=android`). It uses the platform's own classes only - no androidx,
// no Gradle - so javac and d8 against android.jar are all it needs.
package zimr.android;

import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.graphics.Color;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Bundle;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URLConnection;

public final class WebViewActivity extends Activity {
    // The assets are served from this pretend https host: an https page is a secure context, which WebGPU requires,
    // and its fixed origin keeps the page's localStorage from one launch to the next. It is the host androidx's
    // WebViewAssetLoader uses, reserved by Android for exactly this; nothing is fetched from the network.
    static final String ASSET_HOST = "appassets.androidplatform.net";
    static final String START_URL = "https://" + ASSET_HOST + "/index.html";

    private WebView webView;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // A debug build (aapt2 --debug-mode) lets desktop Chrome inspect the page: chrome://inspect, over USB.
        boolean appIsDebuggable = (getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0;
        WebView.setWebContentsDebuggingEnabled(appIsDebuggable);

        webView = new WebView(this);
        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setMediaPlaybackRequiresUserGesture(false);
        webView.setWebViewClient(new AssetClient());

        // The page fills the screen, system bars hidden, but stays clear of a camera cutout: the frame around it is
        // padded by the cutout's insets (a WebView ignores its own padding).
        FrameLayout frame = new FrameLayout(this);
        frame.setBackgroundColor(Color.BLACK);
        frame.addView(webView);
        frame.setOnApplyWindowInsetsListener((view, insets) -> {
            Insets cutout = insets.getInsets(WindowInsets.Type.displayCutout());
            view.setPadding(cutout.left, cutout.top, cutout.right, cutout.bottom);
            return insets;
        });
        setContentView(frame);
        webView.loadUrl(START_URL);
    }

    // Bars come back after a swipe, or after another app had the screen; hide them again whenever the page has focus.
    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        WindowInsetsController controller = getWindow().getInsetsController();
        if (hasFocus && controller != null) {
            controller.hide(WindowInsets.Type.systemBars());
            controller.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
        }
    }

    // In the background the page's timers stop too, not only its drawing.
    @Override
    protected void onPause() {
        webView.onPause();
        webView.pauseTimers();
        super.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        webView.resumeTimers();
        webView.onResume();
    }

    @Override
    protected void onDestroy() {
        webView.destroy();
        super.onDestroy();
    }

    // Serves assets/ at https://appassets.androidplatform.net/, and opens every other address in the phone's browser
    // rather than navigating away from the app.
    private final class AssetClient extends WebViewClient {
        @Override
        public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
            Uri url = request.getUrl();
            if (!ASSET_HOST.equals(url.getHost())) {
                return null;
            }
            String path = url.getPath() == null ? "" : url.getPath();
            String assetName = path.startsWith("/") ? path.substring(1) : path;
            String mimeType = mimeTypeOf(assetName);
            String encoding = mimeType.startsWith("text/") ? "utf-8" : null;
            try {
                InputStream asset = getAssets().open(assetName);
                return new WebResourceResponse(mimeType, encoding, asset);
            } catch (IOException missing) {
                InputStream empty = new ByteArrayInputStream(new byte[0]);
                return new WebResourceResponse("text/plain", "utf-8", 404, "Not Found", null, empty);
            }
        }

        @Override
        public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
            Uri url = request.getUrl();
            if (ASSET_HOST.equals(url.getHost())) {
                return false;
            }
            try {
                startActivity(new Intent(Intent.ACTION_VIEW, url));
            } catch (ActivityNotFoundException noBrowser) {
                // Nothing on the phone opens this address: stay on the page.
            }
            return true;
        }
    }

    // WebAssembly.instantiateStreaming insists on application/wasm, which Android's table does not know.
    static String mimeTypeOf(String assetName) {
        if (assetName.endsWith(".wasm")) {
            return "application/wasm";
        }
        String guessed = URLConnection.guessContentTypeFromName(assetName);
        return guessed == null ? "application/octet-stream" : guessed;
    }
}
