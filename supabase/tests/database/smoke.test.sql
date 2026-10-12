begin;

create extension if not exists pgtap with schema extensions;

select extensions.plan(2);
select extensions.ok(true, 'pgTAP smoke test');
select extensions.is((select e.extnamespace::regnamespace::text from pg_catalog.pg_extension as e where e.extname = 'pgcrypto'), 'extensions', 'pgcrypto is declared in extensions');

select * from extensions.finish();

rollback;
