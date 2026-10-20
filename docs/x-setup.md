# Post to X with pnow

pnow posts to X through your own X developer app. X bills that app for each post, so you pay only for your own posts. You set it up once.

## Cost

X has no free API tier. It charges per request from prepaid credits ([pricing](https://docs.x.com/x-api/getting-started/pricing)). In October 2026:

- A post: $0.015.
- A post with a link: $0.20.
- Connecting your account in pnow: $0.01, once.

pnow calls the API only when you post. Posting once a day costs about $0.45 a month.

## 1. Create the app

1. Go to [console.x.com](https://console.x.com) and sign in with your X account. If the console asks, sign up as a developer.
2. Open **Apps** and click **Create App**. Any name works, for example `pnow`.
3. The console then shows an API key, an API secret and a bearer token. pnow does not use them. Do not share them.

## 2. Set up the login

Open the app's **User authentication settings** and set:

| Setting | Value |
| --- | --- |
| App permissions | Read and write |
| Type of App | Native App |
| Callback URL | `pnow://oauth/x` |
| Website URL | `https://github.com/tarasyarema/pnow` |

Save. **Keys and tokens** now shows an OAuth 2.0 **Client ID**. A Native App has no client secret. If you see a client secret, the type of app is wrong.

## 3. Add credits

Open **Billing**:

1. Buy credits.
2. Set a spending limit, for example $10 per billing cycle.

When your credits or your limit run out, X refuses posts until you add more.

## 4. Connect pnow

1. Open pnow's Settings (`⌘,`).
2. Paste the Client ID in **X client ID**.
3. Click **Connect** and log in to X.

pnow saves the client ID in `~/.config/pnow/config.json`. You can also write it there yourself:

```json
{
  "x": {
    "clientID": "<your client ID>"
  }
}
```

Your X login stays in the macOS keychain.

## 5. Post

In the composer, press `⇥` or `⌘T` to post to dev-null.sh, X, or both. While X is on, the composer counts characters the way X does: 280 at most, and 23 for each link.

X's API takes a reply only in your own thread, or when the author mentions you. For a reply to anyone else's X post, pnow opens X's composer in your browser with your text filled in. Any images go on your clipboard, so you can paste them there with `⌘V`.
