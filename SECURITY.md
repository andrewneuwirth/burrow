# Security

Please report vulnerabilities privately through GitHub: the repository's **Security** tab → **Report a vulnerability**,
or email hello@newitools.app. Don't open a public issue for a security problem.

Include what you found, how to reproduce it, and the affected version or commit. We'll acknowledge the report as soon as we
can and credit you in the fix unless you'd rather not be named.

In scope: anything that could lose, expose or wrongly move files (copy, move, Trash, undo, Free Up Space, Tidy), the
"reveal" Apple Event and folder-open events Burrow accepts from other apps, the default-file-browser switch, and the AI
Agents page, which reads local agent config files that can hold keys. Burrow has no servers, so there is no hosted service
to test.
