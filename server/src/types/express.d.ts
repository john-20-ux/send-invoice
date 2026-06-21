import 'express-session';
import 'express-serve-static-core';

declare module 'express-serve-static-core' {
  interface Request {
    shopDomain?: string;
    accessToken?: string;
  }
}

declare module 'express-session' {
  interface SessionData {
    state?: string | null;
    shopDomain?: string;
  }
}
