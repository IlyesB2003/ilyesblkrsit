AI Dev Transfer 1.0.0
=====================

مثبّت صغير لنقل بيئة الذكاء الاصطناعي والتطوير من جهاز Mac الحالي إلى حاسوب ويندوز آخر.

المصدر الذي تم تحليله
---------------------
- MacBook Air M4، macOS 27.3، Ollama 0.32.9
- 8 نماذج LLM بحجم 32.97 GB داخل ~/.ollama/models
- Python 3.14.7، Node.js 26.13.1، Flutter 3.47.8 / Dart 3.13.7
- Java 25.0.4 (Android Studio JBR)، Ruby 2.6.10، Perl 5.34.1
- Swift 6.4.2 وClang 21.0.0 (أدوات Apple، غير منقولة)
- Git 2.55.0، uv 0.12.3، SQLite 3.54.0
- لم توجد خوادم MCP مخصصة في إعدادات Claude/Cursor/Codex؛ الموجود MCPs مدمجة داخل Codex وDSH. أضفنا حزمة MCP قابلة للنقل بدلاً منها.

ماذا يفعل المثبّت؟
-------------------
1. يفحص ويندوز والإنترنت والمساحة الحرة.
2. يثبّت Ollama ثم يشغّل خدمته محلياً.
3. ينزّل النماذج الثمانية نفسها من Ollama Registry:
   gemma4:e4b-it-qat, qwen3.5:9b, moondream:latest,
   embeddinggemma:latest, qwen3:4b, qwen2.5:14b,
   bge-m3:latest, qwen3:8b
4. يثبّت اللغات والأدوات عبر winget، مع روابط رسمية كخطة بديلة:
   Python 3.14، Node.js 26، Git، uv، Java 25،
   Flutter/Dart، Ruby، Perl، LLVM/C++.
5. يجهّز حزمة MCP: filesystem, memory, sequential-thinking,
   fetch, git, time، ويكتب إعدادات Claude Desktop وCursor إن وجدا.
6. ينسخ هذا الدليل وسجل الجرد إلى مجلد التثبيت.

لماذا حجم المثبّت صغير؟
-----------------------
لأنه لا يحمل أوزان النماذج (32.97 GB) ولا حزم اللغات (حوالي 5 GB).
هو "bootstrap" ينزّلها من الإنترنت. هذا يجعله سهل النقل عبر USB
أو البريد، لكنه يحتاج اتصالاً بالإنترنت على الحاسوب الجديد.

المتطلبات
---------
- Windows 10 (build 17763 أو أحدث) أو Windows 11، 64-bit.
- صلاحيات مدير (UAC) لأن winget يثبّت بعض الأدوات على مستوى الجهاز.
- إنترنت مستقر.
- مساحة حرة: 42 GB تقريباً مع كل النماذج، أو 8 GB بدون نماذج.
- وقت متوقع: 20 دقيقة إلى عدة ساعات حسب السرعة.

طريقة الاستخدام
---------------
1. انقل AI-Dev-Transfer-Setup.exe إلى حاسوب ويندوز.
2. شغّله. قد يظهر تحذير SmartScreen لأن الملف غير موقّع رقمياً:
   اضغط More info ثم Run anyway.
3. وافق على UAC، ثم اتبع: التالي -> أوافق -> اختر المكونات -> تثبيت الآن.
4. انتظر. لا تغلق النافذة. يمكنك رؤية المهام والسجل مباشرة.
5. عند الانتهاء اضغط "إنهاء"، ثم أعد تشغيل ويندوز مرة واحدة.

بعد إعادة التشغيل
-----------------
- جرّب: ollama list
- جرّب: ollama run qwen3:8b
- جرّب: python --version
- جرّب: node --version
- جرّب: flutter --version
- إعدادات MCP في Claude Desktop:
  %APPDATA%\Claude\claude_desktop_config.json
- الإعداد العام:
  %LOCALAPPDATA%\AI-Dev-Transfer\mcp\mcp-config.json
- السجل:
  %LOCALAPPDATA%\AI-Dev-Transfer\logs

ملاحظات مهمة
------------
- النماذج تُنزّل بالاسم والوسم نفسه. إذا حدّث المزوّد الوسم فقد يختلف
  الملف قليلاً، لكن النموذج يبقى الوظيفة نفسها.
- لا يحتوي المثبّت على مفاتيح API أو أسرار أو ملفات مشاريع.
- لا يتم تعديل إعدادات MCP الموجودة إلا بإضافة الخوادم مع نسخة احتياطية.
- إذا فشل مكوّن، يكمل المثبّت الباقي ويعرض تنبيهاً. راجع السجل.
- لتقليل الحجم: أزل النماذج الكبيرة أو Flutter قبل التثبيت.
- الملف غير موقّع رقمياً. إذا كنت في بيئة مؤسسية، راجع مسؤول الأمن.

استكشاف الأخطاء
---------------
- "No internet": تحقق من الشبكة/الجدار الناري، ثم أعد التشغيل.
- "Not enough free space": أزل بعض النماذج أو حرّر مساحة.
- winget غير موجود: ثبّت App Installer من Microsoft Store، أو أعد المحاولة
  وسيستخدم المثبّت الروابط الرسمية للعناصر الأساسية.
- فشل Ollama: افتح PowerShell كمدير وشغّل: ollama serve
- فشل MCP: افتح Claude Desktop بعد التثبيت، وتأكد من وجود npx وuvx في PATH.

الخصوصية
--------
كل التنزيلات من مصادر رسمية. لا يوجد تتبع أو إرسال بيانات. المثبّت
يكتب فقط داخل %LOCALAPPDATA%\AI-Dev-Transfer ومجلد النماذج الافتراضي
%USERPROFILE%\.ollama وإعدادات MCP الخاصة بالمستخدم.

لغات البرمجة المتاحة في الإصدار 1.2
-----------------------------------
الويب: HTML و CSS (محرّر VS Code مع Live Server وPrettier وTailwind)،
       JavaScript (Node.js وBun وDeno)، TypeScript، Sass، Less، ESLint، pnpm، Yarn.
الأنظمة: C و C++ (LLVM/Clang، GCC، MSVC عند الحاجة)، Fortran، Go، Rust، Zig،
         Nim، Swift، CMake، Ninja.
‏.NET و JVM: C# و F# و VB.NET (.NET SDK 10)، Java 25، Kotlin، Scala، Groovy،
         Clojure (clj + Babashka)، Gradle، Maven.
السكربت والبيانات: Python (مع NumPy وPandas وJupyterLab)، PHP، Ruby، Perl، Lua،
         PowerShell 7، SQL/SQLite، R، Julia، Erlang، Elixir، Racket (Lisp/Scheme)،
         OCaml، Pascal، Haskell (Stack + GHC).
الجوال: Dart و Flutter.
اختياري (غير محدد افتراضياً): Swift، أدوات MSVC، RStudio، Android Studio، Docker.

كيف يعمل كل شيء تلقائياً:
- Rust: يُثبَّت من rustup الرسمي. إن لم توجد أدوات MSVC يستعمل نسخة GNU
  فلا يحتاج تنزيل 3.5 GB.
- MSVC: لا يُنزَّل إلا مع Swift، ويُتخطّى إن كان مثبّتاً من قبل.
- Kotlin: أحدث إصدار من GitHub، وإن تعذّر ذلك يُستعمل رابط ثابت (2.2.20).
- Flutter: الإصدار 3.47.8 نفسه الموجود على الماك، وإن فشل فأحدث إصدار مستقر.
- Gradle وMaven: أحدث إصدار مستقر من المواقع الرسمية.
- Clojure: الأمر clj يعمل داخل PowerShell، وBabashka (bb) يعمل في أي طرفية.
- OCaml: يُشغَّل opam init تلقائياً، وHaskell: يُشغَّل stack setup تلقائياً.
  هاتان الخطوتان قد تستغرقان 10 إلى 30 دقيقة.
- المكوّنات المطلوبة (Java، Erlang، Node.js، Python، MSVC) تُضاف تلقائياً.

الفحص بعد التثبيت:
- في النهاية يشغّل المثبّت كل لغة (مثل go version وrustc --version) ويكتب
  النتيجة في: %LOCALAPPDATA%\AI-Dev-Transfer\verify-report.txt
- إذا لم يجد لغةً في PATH يبحث عنها في مجلدات تثبيتها المعروفة ويصلح PATH.
- ما يظهر MISSING: أعد تشغيل ويندوز ثم شغّل المثبّت مرة ثانية. سيتخطّى ما
  ثُبّت ويعيد محاولة الباقي فقط.
- HTML و CSS لا تحتاجان تثبيتاً؛ يكفي المحرّر والمتصفح (Edge موجود في ويندوز).
