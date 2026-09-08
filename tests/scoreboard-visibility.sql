-- Regression check against existing memberships. All changes are rolled back.
BEGIN;
DO $$
DECLARE
    target uuid;
    visible_before integer;
    visible_hidden integer;
    visible_restored integer;
BEGIN
    SELECT m."UserId" INTO target FROM "UserParticipations" m
    JOIN "AspNetUsers" u ON u."Id" = m."UserId"
    WHERE NOT u."HideFromScoreboard" LIMIT 1;
    IF target IS NULL THEN RAISE EXCEPTION 'No visible account with a game membership to test'; END IF;
    SELECT count(*) INTO visible_before FROM "Participations" p
    WHERE NOT EXISTS (SELECT 1 FROM "UserParticipations" m JOIN "AspNetUsers" u ON u."Id" = m."UserId"
                      WHERE m."ParticipationId" = p."Id" AND u."HideFromScoreboard");
    UPDATE "AspNetUsers" SET "HideFromScoreboard" = true WHERE "Id" = target;
    SELECT count(*) INTO visible_hidden FROM "Participations" p
    WHERE NOT EXISTS (SELECT 1 FROM "UserParticipations" m JOIN "AspNetUsers" u ON u."Id" = m."UserId"
                      WHERE m."ParticipationId" = p."Id" AND u."HideFromScoreboard");
    IF visible_hidden >= visible_before THEN RAISE EXCEPTION 'Hidden account still appears in standings'; END IF;
    UPDATE "AspNetUsers" SET "HideFromScoreboard" = false WHERE "Id" = target;
    SELECT count(*) INTO visible_restored FROM "Participations" p
    WHERE NOT EXISTS (SELECT 1 FROM "UserParticipations" m JOIN "AspNetUsers" u ON u."Id" = m."UserId"
                      WHERE m."ParticipationId" = p."Id" AND u."HideFromScoreboard");
    IF visible_restored <> visible_before THEN RAISE EXCEPTION 'Unhiding did not restore standings'; END IF;
    RAISE NOTICE 'PASS: hidden account excluded; unhiding restores membership';
END $$;
ROLLBACK;
