ALTER TABLE accounts ADD COLUMN key_envelope TEXT;

CREATE UNIQUE INDEX pairing_challenges_active_code_idx
  ON pairing_challenges(code_hash)
  WHERE state IN ('pending', 'approved');
