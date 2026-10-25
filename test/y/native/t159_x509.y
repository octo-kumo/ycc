// std/x509 on a chain made for it: an RSA root, an ECDSA P-384
// intermediate it signed (SHA-256), a P-256 leaf that one signed
// (SHA-384) for test.example and *.wild.example, valid 2024-2100.
import x509;
let root = "-----BEGIN CERTIFICATE-----\nMIICvDCCAaSgAwIBAgIBATANBgkqhkiG9w0BAQsFADAWMRQwEgYDVQQDDAtZIFRl\nc3QgUm9vdDAgFw0yMDAxMDEwMDAwMDBaGA8yMTIwMDEwMTAwMDAwMFowFjEUMBIG\nA1UEAwwLWSBUZXN0IFJvb3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB\nAQCtL6FesYBaPpeQZogTKSHYpJS/ZlnYRn0Q2+kGE33gjAco2azKVtlfWQ083GNz\n9dMucB9M3zJEdWIZMbpxAnqhB0XlQlcJnOMN73A/1JX5h6r5J8UrP6xIBmEW3lLP\ngff0WoNgDHS2AU4Nj0pDFjnyAE0rDrIec3GjvL8PdNgLZ/r6eeot2Y25QTa1Hdo8\nwkWxx7VM3vOAL3eOdmKVptDncrOYHDEHONron1s8p9dpqA4LwJaoK+J014acMfU+\ni8o5go9fpxRR6qHdC8wQaXENNK+pCDn6OmUNZK52I7x+54vnOa+rqXsvgytihaYY\nuTD2xdoL+fYmLqOY8p90TEGbAgMBAAGjEzARMA8GA1UdEwEB/wQFMAMBAf8wDQYJ\nKoZIhvcNAQELBQADggEBADeZzzywNeZgu/yrNz5FT4mhYoNFjlEzkz0Tf2uQxK1t\n510DLQ2T9OEJQzLQ4Uq4d4tybLUcGUz2mtd+Ada5YTFh15/bHO9NZ6K+9lnjM9rA\nV+F1akNyjQtk37kUemv3VzZZiy+5HV6E7DZ01w4FzfjWshBKFRtEkUj3g5n5Ij7F\n41NTVcTxT6C0COWioAgJk7PovWvRViaWs5A6gSFLtQVSACOmUb+7MypbVYgkUl+Y\nNogV6xaN7qox4TAwmgJ4SUX1v3PUTFIocxfJIo/c/OV250bhpGvpPR6/qAToCls5\n3D0PlVmXiY1OwWIvQOIEvkLXZEzlCfFHmrbZAs8Mnoc=\n-----END CERTIFICATE-----\n";
let inter = "-----BEGIN CERTIFICATE-----\nMIICGTCCAQGgAwIBAgIBAjANBgkqhkiG9w0BAQsFADAWMRQwEgYDVQQDDAtZIFRl\nc3QgUm9vdDAgFw0yMDAxMDEwMDAwMDBaGA8yMTIwMDEwMTAwMDAwMFowHjEcMBoG\nA1UEAwwTWSBUZXN0IEludGVybWVkaWF0ZTB2MBAGByqGSM49AgEGBSuBBAAiA2IA\nBIpmR8BUBCyFDS6Of8cSMf434jKX3Ji/b2xqt3JhJF8PggiDh73t2dlhrBAKVeQV\nVc8KD1NYJZ0LOu828+6QXau/ZM/MUdfoLli4UNCOV4QYV5PTrd5gwi0TXglYecg7\nGqMWMBQwEgYDVR0TAQH/BAgwBgEB/wIBADANBgkqhkiG9w0BAQsFAAOCAQEALEbl\navQE3elh5GJVqN0fXm+5Sn8H6TDfAxCxKVwOIwkKLKDWr8tlGoOPn/+bML99q2Kr\nnOrPWTxG9HYQVpkCmX1uWU0Cax4EiZCoJkrh1QQ7bcD1x70voPvo8HVE0RCIgWzU\nJ0zOZqmjAypjjFepwdLPbk9nlDfZRCEw/JXtOmPfi+fZRWaRj/fKwyQ9q1Yd7F6p\n/t9u6HATrUab5mSl18ylzLHmUMoCR9n6xrOY/P3aXiEdm/k7Ta4PidCa2NPyiWep\nnXGxTXDekddJIPzqqzNBWYfMIaVLxG1o4xmXfXKrnfDOcUO25JLAGuyCS/3IO33k\n992iTwQrba6CnzD9bw==\n-----END CERTIFICATE-----\n";
let leaf = "-----BEGIN CERTIFICATE-----\nMIIBcDCB96ADAgECAgEDMAoGCCqGSM49BAMDMB4xHDAaBgNVBAMME1kgVGVzdCBJ\nbnRlcm1lZGlhdGUwIBcNMjQwMTAxMDAwMDAwWhgPMjEwMDAxMDEwMDAwMDBaMBcx\nFTATBgNVBAMMDHRlc3QuZXhhbXBsZTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IA\nBLwL+9tAc4tmUHkdfBL6IbBmcXCH/Zw6jg4qbx8OFI50B0bT0+nu/+pVvSOeQ04U\nkRMxLTiuhzQ9U6cSWvU61Y+jKzApMCcGA1UdEQQgMB6CDHRlc3QuZXhhbXBsZYIO\nKi53aWxkLmV4YW1wbGUwCgYIKoZIzj0EAwMDaAAwZQIwHKfj5DziTR7P4Zn0hGc6\nwCkQdAh/dBJzuEduKsV3bjoKy9nNM5C7ma2FaCqAssIRAjEA458Pmjzkq45COmFb\no5D8tzk+qPz1QtKm11wbt7hl60mL6xYc8odGOXIJpYqmJL3V\n-----END CERTIFICATE-----\n";
let anchors = x509.anchors_pem(root);
let chain = x509.pem_certs(leaf + inter);
let t2030 = x509.days_from_civil(2030, 6, 1) * 86400;
def check(what: str, why: str) { print(what, ": [", why, "]"); };
check("good", x509.verify_chain_with(chain, "test.example", t2030, anchors));
check("wildcard", x509.verify_chain_with(chain, "a.wild.example", t2030, anchors));
check("two labels", x509.verify_chain_with(chain, "a.b.wild.example", t2030, anchors));
check("other host", x509.verify_chain_with(chain, "test.example.com", t2030, anchors));
check("before", x509.verify_chain_with(chain, "test.example", x509.days_from_civil(2023, 12, 31) * 86400, anchors));
check("after", x509.verify_chain_with(chain, "test.example", x509.days_from_civil(2100, 1, 2) * 86400, anchors));
check("no intermediate", x509.verify_chain_with(chain[0:1], "test.example", t2030, anchors));
check("no anchors", x509.verify_chain_with(chain, "test.example", t2030, []));
check("leaf trusted", x509.verify_chain_with(chain[0:1], "test.example", t2030, x509.anchors_pem(leaf)));
let forged = chain[1];
let bad: [[byte]] = [chain[0]];
let changed: [byte] = [];
changed += forged;
changed[len(changed) - 10] = changed[len(changed) - 10] ^ 1;
bad += [changed];
check("bad signature", x509.verify_chain_with(bad, "test.example", t2030, anchors));
let c = x509.parse_cert(chain[0]);
print(c.ok, " ", c.dns, " ", c.is_ca, " ", x509.parse_cert(chain[1]).is_ca, " ", c.not_before == x509.days_from_civil(2024, 1, 1) * 86400);
print(x509.parse_cert(bytes("not a certificate")).ok, " ", len(x509.pem_certs("nothing here")));
