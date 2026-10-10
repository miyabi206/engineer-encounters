begin;

create extension if not exists pgtap with schema extensions;

select extensions.plan(1);
select extensions.ok(true, 'pgTAP smoke test');
select * from extensions.finish();

rollback;
