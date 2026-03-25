## send-message-push

Bu Edge Function, mesaj gönderildikten sonra karşı tarafa FCM push gönderir.

### Gerekli secrets

Supabase Edge Function secrets:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `FIREBASE_SERVICE_ACCOUNT_JSON`

`FIREBASE_SERVICE_ACCOUNT_JSON` değeri, Firebase Admin SDK JSON dosyasının komple string içeriğidir.

### Deploy

```bash
supabase functions deploy send-message-push
```
