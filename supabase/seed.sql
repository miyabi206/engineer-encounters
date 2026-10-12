-- Local development placeholders only. The owner must replace every row with
-- the curated interest list before any hosted seed is considered.
insert into private.interests (interest_id, label_ja, label_en, display_order)
values
    -- Placeholder: replace with the owner's curated value.
    ('placeholder-software', 'ソフトウェア（仮・オーナー差し替え）', 'Software (placeholder; owner to replace)', 10),
    -- Placeholder: replace with the owner's curated value.
    ('placeholder-design', 'デザイン（仮・オーナー差し替え）', 'Design (placeholder; owner to replace)', 20),
    -- Placeholder: replace with the owner's curated value.
    ('placeholder-data', 'データ（仮・オーナー差し替え）', 'Data (placeholder; owner to replace)', 30)
on conflict (interest_id) do nothing;
