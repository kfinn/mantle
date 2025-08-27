const std = @import("std");

const httpz = @import("httpz");
const pg = @import("pg");

const Repo = @import("Repo.zig");

pub fn ControllerContext(comptime App: type) type {
    return struct {
        app: *App,
        repo: Repo,
        request: *httpz.Request,
        response: *httpz.Response,
        session: ?App.Session,
        session_parse_error: ?anyerror,
        helpers: App.controller_helpers = .{},

        pub fn init(app: *App, request: *httpz.Request, response: *httpz.Response) !@This() {
            var session_parse_error: ?anyerror = null;
            var session: ?App.Session = null;
            if (parseSession(app, request)) |parsed_session| {
                session = parsed_session;
            } else |err| {
                session_parse_error = err;
            }

            return .{
                .app = app,
                .repo = Repo.init(response.arena, try app.pg_pool.acquire()),
                .request = request,
                .response = response,
                .session = session,
                .session_parse_error = session_parse_error,
            };
        }

        // TODO: add support for __Host- prefix.
        const session_cookie_name = std.fmt.comptimePrint("{s}-session", .{App.Session.key});
        const session_nonce_cookie_name = std.fmt.comptimePrint("{s}-session-nonce", .{App.Session.key});
        const session_tag_cookie_name = std.fmt.comptimePrint("{s}-session-tag", .{App.Session.key});

        fn parseSession(app: *App, request: *httpz.Request) !App.Session {
            const base64_encrypted_session_zon = request.cookies().get(session_cookie_name) orelse {
                return error.SessionCookieNotFound;
            };

            const base64_decoder = std.base64.standard.Decoder;
            const encrypted_session_zon = try request.arena.alloc(u8, try base64_decoder.calcSizeForSlice(base64_encrypted_session_zon));
            try base64_decoder.decode(encrypted_session_zon, base64_encrypted_session_zon);

            var tag: [std.crypto.aead.aes_gcm.Aes256Gcm.tag_length]u8 = undefined;
            const base64_tag = request.cookies().get(session_tag_cookie_name) orelse {
                return error.TagCookieNotFound;
            };
            if (try base64_decoder.calcSizeForSlice(base64_tag) != std.crypto.aead.aes_gcm.Aes256Gcm.tag_length) {
                return error.TagInvalid;
            }
            try base64_decoder.decode(&tag, base64_tag);

            var nonce: [std.crypto.aead.aes_gcm.Aes256Gcm.nonce_length]u8 = undefined;
            const base64_nonce = request.cookies().get(session_nonce_cookie_name) orelse {
                return error.NonceCookieNotFound;
            };
            if (try base64_decoder.calcSizeForSlice(base64_nonce) != std.crypto.aead.aes_gcm.Aes256Gcm.nonce_length) {
                return error.NonceInvalid;
            }
            try base64_decoder.decode(&nonce, base64_nonce);

            const session_zon = try request.arena.allocSentinel(u8, encrypted_session_zon.len, 0);

            try std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(
                session_zon,
                encrypted_session_zon,
                tag,
                "",
                nonce,
                app.config.session.cookie_secret_key.*,
            );

            return try std.zon.parse.fromSlice(
                App.Session,
                request.arena,
                session_zon,
                null,
                .{
                    .ignore_unknown_fields = true,
                    .free_on_error = false,
                },
            );
        }

        pub fn afterAction(self: *@This()) !void {
            const session = self.session orelse {
                return;
            };

            var session_zon_writer: std.Io.Writer.Allocating = .init(self.request.arena);
            try std.zon.stringify.serialize(
                session,
                .{
                    .whitespace = false,
                    .emit_default_optional_fields = false,
                },
                &session_zon_writer.writer,
            );
            var session_zon = session_zon_writer.toArrayList();
            defer session_zon.deinit(self.request.arena);

            const encrypted_session_zon = try self.response.arena.alloc(u8, session_zon.items.len);

            var tag: [std.crypto.aead.aes_gcm.Aes256Gcm.tag_length]u8 = undefined;

            var nonce: [std.crypto.aead.aes_gcm.Aes256Gcm.nonce_length]u8 = undefined;
            std.crypto.random.bytes(&nonce);

            std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(
                encrypted_session_zon,
                &tag,
                session_zon.items,
                "",
                nonce,
                self.app.config.session.cookie_secret_key.*,
            );

            const base64_encoder = std.base64.standard.Encoder;
            const base64_encrypted_session_zon_buf = try self.response.arena.alloc(u8, base64_encoder.calcSize(encrypted_session_zon.len));
            const base64_encrypted_session_zon = base64_encoder.encode(base64_encrypted_session_zon_buf, encrypted_session_zon);

            const base64_tag_buf = try self.response.arena.alloc(u8, base64_encoder.calcSize(tag.len));
            const base64_tag = base64_encoder.encode(base64_tag_buf, &tag);

            const base64_nonce_buf = try self.response.arena.alloc(u8, base64_encoder.calcSize(nonce.len));
            const base64_nonce = base64_encoder.encode(base64_nonce_buf, &nonce);

            // const host = self.request.header("host").?;
            // var domain_split_iterator = std.mem.splitScalar(u8, host, ':');
            // const domain = domain_split_iterator.first();

            const cookie_opts: httpz.response.CookieOpts = .{
                .max_age = 604800, // one week
                .path = "/",
                // TODO: add more security
                // .domain = domain,
                // .secure = true,
                // .http_only = true,
                // .same_site = .strict,
            };

            try self.response.setCookie(session_cookie_name, base64_encrypted_session_zon, cookie_opts);
            try self.response.setCookie(session_tag_cookie_name, base64_tag, cookie_opts);
            try self.response.setCookie(session_nonce_cookie_name, base64_nonce, cookie_opts);
        }

        pub fn deinit(self: *@This()) void {
            self.repo.deinit();
            self.* = undefined;
        }
    };
}
