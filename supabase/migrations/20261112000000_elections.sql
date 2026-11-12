-- Speaker elections: members vote for a candidate rather than yea/nay.

alter type vote_position add value 'candidate';

alter table votes
  add column kind text not null default 'question' check (kind in ('question', 'election')),
  add column candidates jsonb not null default '[]';   -- [{ "name": "Jeffries", "total": 212 }, ...]

alter table vote_positions add column choice text;      -- candidate named, when position = 'candidate'
