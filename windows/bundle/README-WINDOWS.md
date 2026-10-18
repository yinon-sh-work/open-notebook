# Open Notebook – התקנה על Windows ברשת סגורה (בלי Docker)

## 1. בניית החבילה (במחשב עם אינטרנט)

ב-GitHub של הפורק: **Actions → "Build Windows Offline Bundle" → Run workflow**.
בסיום, הורד את ה-Artifact בשם `OpenNotebook-Windows-offline` (קובץ ZIP).

אפשרות חלופית – במחשב Windows עם אינטרנט, uv ו-Node.js 22:
```powershell
powershell -ExecutionPolicy Bypass -File windows\build-offline-bundle.ps1 -Zip
```

## 2. התקנה ברשת הסגורה

1. העבר את ה-ZIP למחשב היעד וחלץ אותו, למשל ל-`C:\OpenNotebook`.
   (עדיף נתיב בלי רווחים ומחוץ ל-Program Files.)
2. לחץ פעמיים על **`Start-OpenNotebook.bat`**.
   בהפעלה הראשונה נוצר קובץ `.env` עם מפתח הצפנה אקראי. **גבה את `.env`** – הוא מפענח את מפתחות ה-API השמורים.
3. הדפדפן ייפתח בכתובת `http://127.0.0.1:8502`.

עצירה: **`Stop-OpenNotebook.bat`**. לוגים: תיקיית `logs\`.

## 3. חיבור המודלים ברשת שלך

**Settings → Models**:

1. **Add credential** → ספק **OpenAI Compatible**:
   - Base URL: כתובת הבסיס של שרת המודלים, שמסתיימת ב-`/v1`
   - API Key: המפתח של המודל מהפורטל
   - **Test Connection**
   לכל מודל עם מפתח נפרד בפורטל – צור credential נפרד.
2. הוסף מודלים (Discover או ידנית) ושייך כל אחד ל-credential שלו:
   - **Language** – מודל השיחה/סיכום (למשל Qwen)
   - **Embedding** – לחיפוש סמנטי (אם יש ברשת)
   - **Speech to Text** – לתמלול קבצי אודיו/וידאו (Whisper)
   - **Text to Speech** – לפודקאסטים (אם יש ברשת)
3. קבע את ברירות המחדל לכל סוג.

## 4. תעודת CA פנימית

כברירת מחדל (`OPEN_NOTEBOOK_USE_SYSTEM_CERTS=true`) האפליקציה סומכת על תעודות
שמותקנות ב-Windows תחת *Trusted Root Certification Authorities*.
אם ה-CA לא מותקן שם, הגדר ב-`.env`:
```
ESPERANTO_SSL_CA_BUNDLE=C:\certs\internal-ca.crt
```

## 5. גישה ממחשבים אחרים ברשת (אופציונלי)

ב-`.env`:
```
FRONTEND_HOST=0.0.0.0
API_HOST=0.0.0.0
API_URL=http://<שם-או-IP-של-השרת>:5055
OPEN_NOTEBOOK_PASSWORD=<סיסמה>
```
ופתח את פורטים 8502 ו-5055 ב-Windows Firewall.

## 6. הפעלה אוטומטית בכניסה ל-Windows (אופציונלי)

ב-PowerShell (מתוך תיקיית ההתקנה):
```powershell
$a = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PWD\Start-OpenNotebook.ps1`" -NoBrowser"
Register-ScheduledTask -TaskName "OpenNotebook" -Action $a -Trigger (New-ScheduledTaskTrigger -AtLogOn) -RunLevel Limited
```

## פתרון תקלות

| תסמין | מה לבדוק |
|---|---|
| `CERTIFICATE_VERIFY_FAILED` | ה-CA לא מותקן ב-Windows → סעיף 4 |
| "surrealdb did not start" | פורט 8000 תפוס → `SURREAL_PORT` ב-`.env`; `logs\surrealdb.err.log` |
| מקורות נתקעים ב-"processing" | `logs\worker.err.log` |
| אודיו/וידאו לא מתומללים | חסר מודל Speech to Text, או חסר `bin\ffmpeg.exe` |

גיבוי: תיקיית `db\` (בסיס הנתונים), `app\data\` (קבצים שהועלו) ו-`.env`. עצור את האפליקציה לפני הגיבוי.
