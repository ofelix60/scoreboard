from psycopg.conninfo import conninfo_to_dict

from app import AppSettings, build_conninfo


def test_password_survives_characters_that_mean_something_in_a_url():
    # %41 is the URL encoding of "A"; # ? : and quotes are URL/conninfo syntax.
    password = "a%41b#c?d:e'f g\\h"
    s = AppSettings(
        DB_HOST="h", DB_PORT=5432, DB_USER="u", DB_PASSWORD=password, DB_NAME="d"
    )

    assert conninfo_to_dict(build_conninfo(s))["password"] == password
