BEGIN;

DO $$
BEGIN
  ASSERT app_internal.ru_plural(1, 'новая смена', 'новые смены', 'новых смен') = 'новая смена';
  ASSERT app_internal.ru_plural(3, 'новая смена', 'новые смены', 'новых смен') = 'новые смены';
  ASSERT app_internal.ru_plural(5, 'новая смена', 'новые смены', 'новых смен') = 'новых смен';
  ASSERT app_internal.ru_plural(11, 'новая смена', 'новые смены', 'новых смен') = 'новых смен';
  ASSERT app_internal.ru_plural(12, 'новая смена', 'новые смены', 'новых смен') = 'новых смен';
  ASSERT app_internal.ru_plural(21, 'новая смена', 'новые смены', 'новых смен') = 'новая смена';
  ASSERT app_internal.ru_plural(104, 'новая смена', 'новые смены', 'новых смен') = 'новые смены';
  ASSERT app_internal.ru_plural(0, 'новая смена', 'новые смены', 'новых смен') = 'новых смен';
  RAISE NOTICE 'ok: ru_plural';
END $$;

DO $$
BEGIN
  ASSERT app_internal.city_locative('spb') = 'Петербурге';
  ASSERT app_internal.city_locative('moscow') = 'Москве';
  ASSERT app_internal.city_locative('kazan') = 'kazan';
  ASSERT app_internal.city_locative(NULL) = '';
  ASSERT app_internal.city_name('spb') = 'Петербург';
  ASSERT app_internal.city_name('moscow') = 'Москва';
  RAISE NOTICE 'ok: city_locative / city_name';
END $$;

DO $$
BEGIN
  ASSERT app_internal.render_template(
    '{count} {shifts} у м. {metro}',
    '{"count":"3","shifts":"новые смены","metro":"Чернышевская"}'
  ) = '3 новые смены у м. Чернышевская';
  ASSERT app_internal.render_template('{count} в {city}, {unknown}', '{"count":"5","city":"Петербурге"}')
    = '5 в Петербурге, {unknown}';
  ASSERT app_internal.render_template('plain', NULL) = 'plain';
  ASSERT app_internal.render_template(NULL, '{"a":"b"}') = '';
  ASSERT app_internal.render_template('{a}', '"scalar"') = '{a}';
  RAISE NOTICE 'ok: render_template';
END $$;

DO $$
BEGIN
  ASSERT NOT has_function_privilege('anon', 'app_internal.ru_plural(int,text,text,text)', 'EXECUTE');
  ASSERT NOT has_function_privilege('authenticated', 'app_internal.render_template(text,jsonb)', 'EXECUTE');
  ASSERT has_function_privilege('service_role', 'app_internal.city_locative(text)', 'EXECUTE');
  RAISE NOTICE 'ok: grants';
END $$;

ROLLBACK;
