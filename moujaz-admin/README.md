# MOUJAZ Admin V1 — لوحة الإدارة المنفصلة

## التشغيل

1. أنشئ `.env.local` اعتماداً على `.env.example`، وضع **نفس** Project URL وPublishable Key المستخدمين في موقع الطلاب.
2. في Supabase > SQL Editor، شغّل `supabase/02_admin_setup.sql` **بعد** إنشاء جدول orders وتشغيل ملف 01_secure_orders.sql من مشروع الطلاب.
3. من Supabase > Authentication > Users انسخ **User UID** الخاص بحساب Google الإداري.
4. في SQL Editor شغّل (بعد استبدال القيمة بمعرّفك الفعلي):

```sql
insert into public.admin_members (user_id,role)
values ('YOUR_AUTH_USER_UUID','OWNER')
on conflict (user_id) do update set role='OWNER';
```

5. في Supabase > Authentication > URL Configuration أضف `http://localhost:3001/**` إلى Redirect URLs. إذا أردت اختبار تسجيل الدخول من هاتف على عنوان LAN أضف عنوان الجهاز المناسب أيضاً إلى Redirect URLs. لا تستبدل إعدادات موقع الطلاب على المنفذ 3000.
6. شغّل:

```bash
npm install
npm run dev
```

7. افتح http://localhost:3001 وسجّل بنفس Google الذي أضفته كـ OWNER.

## ميزات النسخة

- لوحة إحصائيات وطلبات قابلة للبحث والتصفية.
- عرض جميع تفاصيل الطلبات، وفتح تيليجرام الطالب.
- تأكيد الدفع يدوياً وتحديث حالة الطلب من خلال دالة Supabase محمية.
- OWNER و ADMIN يستطيعان التعديل، EMPLOYEE للعرض فقط في هذه النسخة.
- نفس مشروع Supabase الخاص بموقع الطلاب؛ لا حاجة لقاعدة بيانات جديدة.

## مهم قبل الإطلاق

- **لا تضع service_role أو secret key في أي متغير NEXT_PUBLIC.**
- بيانات الإدارة حساسة. استخدم HTTPS عند النشر، وتحقق من سياسات RLS والصلاحيات.
- هذه نسخة أولية: لا تحتوي بعد على سجل تدقيق للتغييرات أو تعيين موظفين أو إشعارات فورية أو إدارة أكواد الخصم.
- الاستعلام يعرض أحدث 500 طلب؛ أضف pagination عند زيادة الطلبات.
- لا تغيّر الحالة إلى «تم التسليم» إلا بعد إرسال الملف النهائي عبر تيليجرام.
- تسجيل Google قد يتطلب إضافة رابط النشر ضمن إعدادات Supabase وGoogle OAuth حسب طريقة إعدادك.
